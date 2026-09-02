#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <sys/mman.h>
#import <dlfcn.h>
#import <unistd.h>

#ifndef SEG_DATA_CONST
#define SEG_DATA_CONST "__DATA_CONST"
#endif
#ifndef SEG_AUTH_CONST
#define SEG_AUTH_CONST "__AUTH_CONST"
#endif
#ifndef SEG_AUTH
#define SEG_AUTH "__AUTH"
#endif

/**
 * EasyComix Gemini Tweak (Dylib)
 * - Chặn toàn diện 100% request dịch (Dịch Classic Chapter & Dịch Live Scroll/Paged) chuyển qua Gemini API
 * - Mở khóa vĩnh viễn hạn mức PRO (999,999 lượt cho cả Dịch thường & Dịch Live)
 * - Tự động tái tạo JSON đúng 100% theo kiểu Swift Decodable của EasyComix
 * - Tự động xoay Key khi gặp lỗi Rate Limit (HTTP 429) hoặc lỗi Key
 * - Tùy chọn model: gemini-3.5-flash-lite (mặc định), gemini-3.1-flash-lite
 */

#define LOG(fmt, ...) NSLog(@"[EasyComixGemini] " fmt, ##__VA_ARGS__)

static NSString *const kGeminiKeysPref  = @"EasyComix_Gemini_Key_Pool";
static NSString *const kGeminiModelPref = @"EasyComix_Gemini_Model_Name";
static NSString *const kGemini35Model   = @"gemini-3.5-flash-lite"; // Mặc định
static NSString *const kGemini31Model   = @"gemini-3.1-flash-lite";

static NSUInteger sCurrentKeyIndex = 0;

// =========================================================================
// QUẢN LÝ KEY POOL & MODEL
// =========================================================================

static NSArray<NSString *> *ParseAndCleanGeminiKeys(NSString *rawInput) {
    if (!rawInput || [rawInput length] == 0) return @[];
    
    // Tách theo nhiều loại ký tự phân cách: xuống dòng, tab, phẩy, chấm phẩy, khoảng trắng, gạch đứng, dấu nháy, ngoặc vuông/nhọn
    NSCharacterSet *delimiters = [NSCharacterSet characterSetWithCharactersInString:@"\r\n,;|\"'` \t[]{}()"];
    NSArray *components = [rawInput componentsSeparatedByCharactersInSet:delimiters];
    
    NSMutableArray<NSString *> *validKeys = [NSMutableArray array];
    NSMutableSet<NSString *> *seenKeys = [NSMutableSet set];
    
    for (NSString *item in components) {
        NSString *trimmed = [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        // Loại bỏ các tiền tố như gạch đầu dòng, số thứ tự (ví dụ: "1.", "-", "*")
        while ([trimmed hasPrefix:@"-"] || [trimmed hasPrefix:@"*"] || [trimmed hasPrefix:@">"]) {
            trimmed = [[trimmed substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        
        // Gemini API Key tiêu chuẩn thường bắt đầu bằng AIzaSy và có độ dài ~39 ký tự
        // Chấp nhận mọi chuỗi hợp lệ >= 20 ký tự không chứa khoảng trắng
        if ([trimmed length] >= 20 && ![seenKeys containsObject:trimmed]) {
            [validKeys addObject:trimmed];
            [seenKeys addObject:trimmed];
        }
    }
    return validKeys;
}

static NSArray<NSString *> *GetGeminiKeyPool(void) {
    NSString *rawKeys = [[NSUserDefaults standardUserDefaults] stringForKey:kGeminiKeysPref];
    return ParseAndCleanGeminiKeys(rawKeys);
}

static NSString *GetSavedGeminiModel(void) {
    NSString *model = [[NSUserDefaults standardUserDefaults] stringForKey:kGeminiModelPref];
    if ([model isEqualToString:kGemini31Model]) {
        return kGemini31Model;
    }
    return kGemini35Model;
}

static void SaveGeminiSettings(NSString *rawKeys, NSString *model) {
    NSArray<NSString *> *parsed = ParseAndCleanGeminiKeys(rawKeys);
    NSString *cleanKeysText = [parsed componentsJoinedByString:@"\n"];
    
    NSString *safeModel = [model isEqualToString:kGemini31Model] ? kGemini31Model : kGemini35Model;
    
    [[NSUserDefaults standardUserDefaults] setObject:cleanKeysText forKey:kGeminiKeysPref];
    [[NSUserDefaults standardUserDefaults] setObject:safeModel forKey:kGeminiModelPref];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    @synchronized (kGeminiKeysPref) {
        sCurrentKeyIndex = 0;
    }
    LOG(@"Đã lưu cấu hình: %lu keys, model: %@", (unsigned long)[parsed count], safeModel);
}

static NSString *GetKeyForAttempt(NSUInteger attempt, NSUInteger *outIndex, NSUInteger *outTotal) {
    NSArray<NSString *> *keys = GetGeminiKeyPool();
    if (outTotal) *outTotal = [keys count];
    if ([keys count] == 0) {
        if (outIndex) *outIndex = 0;
        return @"";
    }
    
    NSUInteger idx = 0;
    @synchronized (kGeminiKeysPref) {
        idx = (sCurrentKeyIndex + attempt) % [keys count];
    }
    if (outIndex) *outIndex = idx;
    return keys[idx];
}

static void RotateToNextKey(void) {
    NSArray<NSString *> *keys = GetGeminiKeyPool();
    if ([keys count] > 1) {
        @synchronized (kGeminiKeysPref) {
            sCurrentKeyIndex = (sCurrentKeyIndex + 1) % [keys count];
            LOG(@"Đã tự động xoay sang Key #%lu/%lu", (unsigned long)(sCurrentKeyIndex + 1), (unsigned long)[keys count]);
        }
    }
}

// =========================================================================
// GIAO DIỆN CÀI ĐẶT: POPUP QUẢN LÝ NHIỀU KEY & MODEL (MODAL TỰ TẠO)
// =========================================================================

@interface GeminiSettingsViewController : UIViewController <UITextViewDelegate>
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *placeholderLabel;
@property (nonatomic, strong) UISegmentedControl *modelSegment;
@property (nonatomic, strong) UIButton *btnPaste;
@property (nonatomic, strong) UIButton *btnClean;
@property (nonatomic, strong) UIButton *btnClear;
@property (nonatomic, strong) UIButton *btnSave;
@property (nonatomic, strong) UIButton *btnClose;
@property (nonatomic, strong) NSLayoutConstraint *cardCenterYConstraint;
@end

@implementation GeminiSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    
    // Tap ngoài để ẩn bàn phím
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];
    
    // Khung Card
    self.cardView = [[UIView alloc] init];
    self.cardView.translatesAutoresizingMaskIntoConstraints = NO;
    self.cardView.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:0.12 green:0.12 blue:0.14 alpha:1.0];
        }
        return [UIColor whiteColor];
    }];
    self.cardView.layer.cornerRadius = 18.0;
    self.cardView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.cardView.layer.shadowOffset = CGSizeMake(0, 8);
    self.cardView.layer.shadowRadius = 20.0;
    self.cardView.layer.shadowOpacity = 0.35;
    [self.view addSubview:self.cardView];
    
    // Stack chính
    UIStackView *mainStack = [[UIStackView alloc] init];
    mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    mainStack.axis = UILayoutConstraintAxisVertical;
    mainStack.spacing = 12.0;
    mainStack.layoutMargins = UIEdgeInsetsMake(18, 18, 18, 18);
    mainStack.layoutMarginsRelativeArrangement = YES;
    [self.cardView addSubview:mainStack];
    
    // Header Stack: Title + Close Button
    UIStackView *headerStack = [[UIStackView alloc] init];
    headerStack.axis = UILayoutConstraintAxisHorizontal;
    headerStack.alignment = UIStackViewAlignmentCenter;
    headerStack.distribution = UIStackViewDistributionFill;
    
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.text = @"🤖 Gemini Key Pool & Model";
    self.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    self.titleLabel.textColor = [UIColor labelColor];
    [headerStack addArrangedSubview:self.titleLabel];
    
    self.btnClose = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.btnClose setTitle:@"✕" forState:UIControlStateNormal];
    self.btnClose.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    [self.btnClose setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    [self.btnClose addTarget:self action:@selector(handleClose) forControlEvents:UIControlEventTouchUpInside];
    [self.btnClose setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [headerStack addArrangedSubview:self.btnClose];
    
    [mainStack addArrangedSubview:headerStack];
    
    // Status Label
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.statusLabel.numberOfLines = 2;
    [mainStack addArrangedSubview:self.statusLabel];
    
    // Text View Container (có placeholder)
    UIView *tvContainer = [[UIView alloc] init];
    tvContainer.translatesAutoresizingMaskIntoConstraints = NO;
    tvContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    tvContainer.layer.cornerRadius = 10.0;
    tvContainer.layer.borderWidth = 0.8;
    tvContainer.layer.borderColor = [UIColor separatorColor].CGColor;
    tvContainer.clipsToBounds = YES;
    
    self.textView = [[UITextView alloc] init];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.backgroundColor = [UIColor clearColor];
    self.textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.textView.textColor = [UIColor labelColor];
    self.textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.textView.autocorrectionType = UITextAutocorrectionTypeNo;
    self.textView.spellCheckingType = UITextSpellCheckingTypeNo;
    self.textView.delegate = self;
    [tvContainer addSubview:self.textView];
    
    self.placeholderLabel = [[UILabel alloc] init];
    self.placeholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.placeholderLabel.text = @"Dán danh sách API Key tại đây...\n(AIzaSy...)\nMỗi dòng 1 key hoặc cách bằng dấu phẩy.";
    self.placeholderLabel.font = [UIFont systemFontOfSize:12];
    self.placeholderLabel.textColor = [UIColor placeholderTextColor];
    self.placeholderLabel.numberOfLines = 0;
    self.placeholderLabel.userInteractionEnabled = NO;
    [tvContainer addSubview:self.placeholderLabel];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.textView.topAnchor constraintEqualToAnchor:tvContainer.topAnchor constant:4],
        [self.textView.leadingAnchor constraintEqualToAnchor:tvContainer.leadingAnchor constant:6],
        [self.textView.trailingAnchor constraintEqualToAnchor:tvContainer.trailingAnchor constant:-6],
        [self.textView.bottomAnchor constraintEqualToAnchor:tvContainer.bottomAnchor constant:-4],
        [self.textView.heightAnchor constraintEqualToConstant:120],
        
        [self.placeholderLabel.topAnchor constraintEqualToAnchor:tvContainer.topAnchor constant:12],
        [self.placeholderLabel.leadingAnchor constraintEqualToAnchor:tvContainer.leadingAnchor constant:12],
        [self.placeholderLabel.trailingAnchor constraintEqualToAnchor:tvContainer.trailingAnchor constant:-12]
    ]];
    
    [mainStack addArrangedSubview:tvContainer];
    
    // Quick Actions Row
    UIStackView *actionsRow = [[UIStackView alloc] init];
    actionsRow.axis = UILayoutConstraintAxisHorizontal;
    actionsRow.distribution = UIStackViewDistributionFillEqually;
    actionsRow.spacing = 8.0;
    
    self.btnPaste = [self createSmallButton:@"📋 Dán Clipboard" action:@selector(handlePaste)];
    self.btnClean = [self createSmallButton:@"🧹 Dọn dẹp Key" action:@selector(handleClean)];
    self.btnClear = [self createSmallButton:@"🗑️ Xóa hết" action:@selector(handleClear)];
    
    [actionsRow addArrangedSubview:self.btnPaste];
    [actionsRow addArrangedSubview:self.btnClean];
    [actionsRow addArrangedSubview:self.btnClear];
    [mainStack addArrangedSubview:actionsRow];
    
    // Model Selection
    UILabel *modelTitle = [[UILabel alloc] init];
    modelTitle.text = @"Chọn Model Gemini:";
    modelTitle.font = [UIFont boldSystemFontOfSize:12];
    modelTitle.textColor = [UIColor secondaryLabelColor];
    [mainStack addArrangedSubview:modelTitle];
    
    self.modelSegment = [[UISegmentedControl alloc] initWithItems:@[ @"3.5 Flash Lite (Mặc định)", @"3.1 Flash Lite" ]];
    NSString *currentModel = GetSavedGeminiModel();
    if ([currentModel isEqualToString:kGemini31Model]) {
        self.modelSegment.selectedSegmentIndex = 1;
    } else {
        self.modelSegment.selectedSegmentIndex = 0; // gemini-3.5-flash-lite mặc định
    }
    [mainStack addArrangedSubview:self.modelSegment];
    
    // Save Button
    self.btnSave = [UIButton buttonWithType:UIButtonTypeSystem];
    self.btnSave.translatesAutoresizingMaskIntoConstraints = NO;
    [self.btnSave setTitle:@"💾 Lưu cấu hình" forState:UIControlStateNormal];
    self.btnSave.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [self.btnSave setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.btnSave.backgroundColor = [UIColor colorWithRed:0.08 green:0.52 blue:1.0 alpha:1.0];
    self.btnSave.layer.cornerRadius = 10.0;
    [self.btnSave addTarget:self action:@selector(handleSave) forControlEvents:UIControlEventTouchUpInside];
    [self.btnSave.heightAnchor constraintEqualToConstant:44].active = YES;
    [mainStack addArrangedSubview:self.btnSave];
    
    // Nạp dữ liệu hiện tại
    NSArray<NSString *> *existing = GetGeminiKeyPool();
    if ([existing count] > 0) {
        self.textView.text = [existing componentsJoinedByString:@"\n"];
    }
    [self updateKeyCountDisplay];
    
    // Layout Constraints cho Card
    self.cardCenterYConstraint = [self.cardView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor];
    [NSLayoutConstraint activateConstraints:@[
        self.cardCenterYConstraint,
        [self.cardView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.cardView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.cardView.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.cardView.widthAnchor constraintLessThanOrEqualToConstant:400],
        [self.cardView.widthAnchor constraintGreaterThanOrEqualToConstant:320],
        
        [mainStack.topAnchor constraintEqualToAnchor:self.cardView.topAnchor],
        [mainStack.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor],
        [mainStack.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor],
        [mainStack.bottomAnchor constraintEqualToAnchor:self.cardView.bottomAnchor]
    ]];
}

- (UIButton *)createSmallButton:(NSString *)title action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:title forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    [btn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    btn.backgroundColor = [UIColor tertiarySystemFillColor];
    btn.layer.cornerRadius = 6.0;
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [btn.heightAnchor constraintEqualToConstant:28].active = YES;
    return btn;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)keyboardWillShow:(NSNotification *)notification {
    NSDictionary *info = [notification userInfo];
    CGRect kbFrame = [info[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    NSTimeInterval duration = [info[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    
    CGFloat offset = -(kbFrame.size.height / 2.0) + 30;
    self.cardCenterYConstraint.constant = offset;
    [UIView animateWithDuration:duration animations:^{
        [self.view layoutIfNeeded];
    }];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    NSDictionary *info = [notification userInfo];
    NSTimeInterval duration = [info[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    
    self.cardCenterYConstraint.constant = 0;
    [UIView animateWithDuration:duration animations:^{
        [self.view layoutIfNeeded];
    }];
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (void)textViewDidChange:(UITextView *)textView {
    [self updateKeyCountDisplay];
}

- (void)updateKeyCountDisplay {
    NSArray<NSString *> *keys = ParseAndCleanGeminiKeys(self.textView.text);
    NSUInteger count = [keys count];
    if (count == 0) {
        self.statusLabel.text = @"⚠️ Chưa có Key nào. Dán 1 hoặc nhiều key để dịch.";
        self.statusLabel.textColor = [UIColor systemOrangeColor];
        self.placeholderLabel.hidden = (self.textView.text.length > 0);
    } else {
        self.statusLabel.text = [NSString stringWithFormat:@"✅ Đã nhận diện %lu Key hợp lệ (Tự động xoay vòng)", (unsigned long)count];
        self.statusLabel.textColor = [UIColor systemGreenColor];
        self.placeholderLabel.hidden = YES;
    }
}

- (void)handlePaste {
    NSString *pb = [UIPasteboard generalPasteboard].string;
    if (pb.length > 0) {
        if (self.textView.text.length > 0) {
            self.textView.text = [NSString stringWithFormat:@"%@\n%@", self.textView.text, pb];
        } else {
            self.textView.text = pb;
        }
        [self handleClean];
    }
}

- (void)handleClean {
    NSArray<NSString *> *keys = ParseAndCleanGeminiKeys(self.textView.text);
    self.textView.text = [keys componentsJoinedByString:@"\n"];
    [self updateKeyCountDisplay];
}

- (void)handleClear {
    self.textView.text = @"";
    [self updateKeyCountDisplay];
}

- (void)handleSave {
    [self dismissKeyboard];
    
    NSString *selectedModel = (self.modelSegment.selectedSegmentIndex == 1) ? kGemini31Model : kGemini35Model;
    
    SaveGeminiSettings(self.textView.text, selectedModel);
    
    [self.btnSave setTitle:@"✓ Đã lưu thành công!" forState:UIControlStateNormal];
    self.btnSave.backgroundColor = [UIColor systemGreenColor];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self dismissViewControllerAnimated:YES completion:nil];
    });
}

- (void)handleClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

static UIViewController *GetTopViewController(void) {
    UIWindow *keyWindow = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if ([w isKeyWindow]) {
            keyWindow = w;
            break;
        }
    }
    if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
    UIViewController *topVC = keyWindow.rootViewController;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    return topVC;
}

static void ShowGeminiSettingsPopup(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *topVC = GetTopViewController();
        if (!topVC) return;
        if ([topVC isKindOfClass:[GeminiSettingsViewController class]]) {
            return;
        }
        
        GeminiSettingsViewController *vc = [[GeminiSettingsViewController alloc] init];
        vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
        vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        [topVC presentViewController:vc animated:YES completion:nil];
    });
}

// Nút nổi kéo thả trên màn hình
@interface GeminiFloatingButton : UIButton
@end

@implementation GeminiFloatingButton

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor colorWithRed:0.08 green:0.52 blue:1.0 alpha:0.92];
        [self setTitle:@"🤖 Key" forState:UIControlStateNormal];
        self.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        self.layer.cornerRadius = frame.size.width / 2.0;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        self.layer.shadowRadius = 4;
        self.layer.shadowOpacity = 0.35;
        self.clipsToBounds = NO;
        
        [self addTarget:self action:@selector(buttonTapped) forControlEvents:UIControlEventTouchUpInside];
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}

- (void)buttonTapped {
    ShowGeminiSettingsPopup();
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self.superview];
}

@end

static void AddFloatingButtonToWindow(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIWindow *keyWindow = nil;
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if ([w isKeyWindow]) {
                    keyWindow = w;
                    break;
                }
            }
            if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
            if (keyWindow) {
                GeminiFloatingButton *btn = [[GeminiFloatingButton alloc] initWithFrame:CGRectMake(16, 160, 52, 52)];
                [keyWindow addSubview:btn];
                [keyWindow bringSubviewToFront:btn];
                
                if ([GetGeminiKeyPool() count] == 0) {
                    ShowGeminiSettingsPopup();
                }
            }
        });
    });
}

// =========================================================================
// GỌI GOOGLE GEMINI REST API
// =========================================================================

static void CallGeminiTranslation(NSArray<NSString *> *texts,
                                  NSString *srcLang,
                                  NSString *tgtLang,
                                  NSString *userContext,
                                  NSUInteger attempt,
                                  NSUInteger maxTries,
                                  void (^completion)(NSArray<NSString *> *translatedTexts)) {
    
    if (!texts || [texts count] == 0) {
        completion(@[]);
        return;
    }
    
    NSUInteger keyIdx = 0;
    NSUInteger totalKeys = 0;
    NSString *currentKey = GetKeyForAttempt(attempt, &keyIdx, &totalKeys);
    NSString *model = GetSavedGeminiModel();
    
    if ([currentKey length] == 0) {
        ShowGeminiSettingsPopup();
        completion(texts);
        return;
    }
    
    LOG(@"[Gemini] Bắt đầu dịch %lu câu bằng Key #%lu/%lu (Model: %@)...", (unsigned long)[texts count], (unsigned long)(keyIdx + 1), (unsigned long)totalKeys, model);
    
    NSError *error = nil;
    NSData *textsJsonData = [NSJSONSerialization dataWithJSONObject:texts options:0 error:&error];
    NSString *textsJsonString = [[NSString alloc] initWithData:textsJsonData encoding:NSUTF8StringEncoding];
    NSString *contextLine = ([userContext isKindOfClass:[NSString class]] && [userContext length] > 0)
        ? [NSString stringWithFormat:@"\nNgữ cảnh truyện: %@\n", userContext]
        : @"";
    
    NSString *prompt = [NSString stringWithFormat:
        @"Bạn là dịch giả truyện tranh / manga / webtoon chuyên nghiệp.\n"
        @"Hãy dịch danh sách các câu thoại sau từ ngôn ngữ '%@' sang '%@'.\n"
        @"%@"
        @"Quy tắc dịch:\n"
        @"- Dịch văn phong tự nhiên, cảm xúc, chuẩn ngữ cảnh thoại truyện tranh.\n"
        @"- Trả về DUY NHẤT một JSON Array mảng chuỗi theo đúng thứ tự (ví dụ: [\"câu 1\", \"câu 2\"]).\n"
        @"- Số phần tử trong mảng kết quả BẮT BUỘC phải bằng đúng %lu.\n"
        @"- KHÔNG thêm bất kỳ markdown hoặc giải thích nào khác.\n\n"
        @"Danh sách cần dịch:\n%@",
        srcLang, tgtLang, contextLine, (unsigned long)[texts count], textsJsonString];
    
    NSDictionary *payload = @{
        @"contents": @[
            @{ @"parts": @[ @{ @"text": prompt } ] }
        ],
        @"generationConfig": @{
            @"responseMimeType": @"application/json",
            @"responseSchema": @{
                @"type": @"ARRAY",
                @"items": @{ @"type": @"STRING" },
                @"minItems": @([texts count]),
                @"maxItems": @([texts count])
            },
            @"temperature": @0.35
        }
    };
    
    NSString *geminiEndpoint = [NSString stringWithFormat:
        @"https://generativelanguage.googleapis.com/v1beta/models/%@:generateContent",
        model];
    
    NSMutableURLRequest *geminiReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:geminiEndpoint]];
    [geminiReq setHTTPMethod:@"POST"];
    [geminiReq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [geminiReq setValue:currentKey forHTTPHeaderField:@"x-goog-api-key"];
    [geminiReq setTimeoutInterval:45.0];
    [geminiReq setHTTPBody:[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil]];
    
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    
    [[session dataTaskWithRequest:geminiReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *netError) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSInteger statusCode = httpResponse ? httpResponse.statusCode : 0;
        
        LOG(@"Gemini (%@) response status: %ld", model, (long)statusCode);
        
        BOOL isKeyOrModelError = (statusCode == 429 || statusCode == 400 || statusCode == 401 || statusCode == 403 || statusCode == 404);
        
        if ((isKeyOrModelError || netError) && attempt < maxTries - 1) {
            LOG(@"Lỗi gọi Gemini (HTTP %ld với Key #%lu/%lu). Đang xoay sang Key tiếp theo...", (long)statusCode, (unsigned long)(keyIdx + 1), (unsigned long)totalKeys);
            RotateToNextKey();
            CallGeminiTranslation(texts, srcLang, tgtLang, userContext, attempt + 1, maxTries, completion);
            return;
        }
        
        NSArray *translatedList = nil;
        if (!netError && data && statusCode == 200) {
            NSDictionary *geminiRes = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *candidates = [geminiRes[@"candidates"] isKindOfClass:[NSArray class]] ? geminiRes[@"candidates"] : nil;
            NSDictionary *candidate = [candidates.firstObject isKindOfClass:[NSDictionary class]] ? candidates.firstObject : nil;
            NSDictionary *content = [candidate[@"content"] isKindOfClass:[NSDictionary class]] ? candidate[@"content"] : nil;
            NSArray *parts = [content[@"parts"] isKindOfClass:[NSArray class]] ? content[@"parts"] : nil;
            NSDictionary *part = [parts.firstObject isKindOfClass:[NSDictionary class]] ? parts.firstObject : nil;
            NSString *rawText = [part[@"text"] isKindOfClass:[NSString class]] ? part[@"text"] : nil;
            if (rawText) {
                NSString *cleanText = [rawText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if ([cleanText hasPrefix:@"```json"]) {
                    cleanText = [cleanText substringFromIndex:7];
                } else if ([cleanText hasPrefix:@"```"]) {
                    cleanText = [cleanText substringFromIndex:3];
                }
                if ([cleanText hasSuffix:@"```"]) {
                    cleanText = [cleanText substringToIndex:[cleanText length] - 3];
                }
                cleanText = [cleanText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                
                NSData *cleanData = [cleanText dataUsingEncoding:NSUTF8StringEncoding];
                id parsed = [NSJSONSerialization JSONObjectWithData:cleanData options:0 error:nil];
                if ([parsed isKindOfClass:[NSArray class]]) {
                    translatedList = (NSArray *)parsed;
                } else if ([parsed isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *pDict = (NSDictionary *)parsed;
                    for (NSString *k in @[@"translations", @"result", @"data", @"translated_texts"]) {
                        if ([pDict[k] isKindOfClass:[NSArray class]]) {
                            translatedList = (NSArray *)pDict[k];
                            break;
                        }
                    }
                }
            }
        }
        
        // Ghép bản dịch đảm bảo đủ số lượng phần tử của texts
        NSMutableArray<NSString *> *finalResult = [NSMutableArray array];
        for (NSUInteger i = 0; i < [texts count]; i++) {
            if (translatedList && i < [translatedList count] && [translatedList[i] isKindOfClass:[NSString class]]) {
                [finalResult addObject:translatedList[i]];
            } else {
                [finalResult addObject:texts[i]];
            }
        }
        
        LOG(@"Dịch hoàn tất %lu câu bằng Gemini (%@)!", (unsigned long)[finalResult count], model);
        completion(finalResult);
    }] resume];
}

// =========================================================================
// TIỆN ÍCH PHÂN TÍCH REQUEST BODY & TẠO RESPONSE QUOTA PRO VĨNH VIỄN
// =========================================================================

static NSData *RequestBodyData(NSURLRequest *request) {
    NSData *body = request.HTTPBody;
    if (body.length > 0) return body;

    NSInputStream *stream = request.HTTPBodyStream;
    if (!stream) return nil;

    NSMutableData *streamData = [NSMutableData data];
    uint8_t buffer[8192];
    [stream open];
    while (YES) {
        NSInteger count = [stream read:buffer maxLength:sizeof(buffer)];
        if (count > 0) {
            [streamData appendBytes:buffer length:(NSUInteger)count];
        } else {
            break;
        }
    }
    [stream close];
    return streamData.length > 0 ? streamData : nil;
}

static NSDictionary *TranslationPayloadFromBodyData(NSData *bodyData) {
    if (bodyData.length == 0) return nil;
    id body = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
    if (![body isKindOfClass:[NSDictionary class]]) return nil;
    id nestedData = ((NSDictionary *)body)[@"data"];
    return [nestedData isKindOfClass:[NSDictionary class]] ? nestedData : body;
}

static NSString *PayloadString(NSDictionary *payload, NSArray<NSString *> *keys, NSString *fallback) {
    for (NSString *key in keys) {
        id value = payload[key];
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
    }
    return fallback;
}

static NSString *ExtractTextFromBubble(id item) {
    if ([item isKindOfClass:[NSString class]]) return (NSString *)item;
    if ([item isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)item;
        for (NSString *k in @[@"text", @"originalText", @"sourceText", @"recognizedText"]) {
            if ([d[k] isKindOfClass:[NSString class]] && [d[k] length] > 0) {
                return d[k];
            }
        }
    }
    return @"";
}

/**
 * Cấu trúc Response Quota PRO chuẩn theo đúng Decodable của Swift EasyComix:
 * QuotaUsageResponse: { quota: QuotaInfo, liveQuota: QuotaInfo }
 * QuotaInfo: { tier: "pro", remaining: 999999, resetAt: null }
 */
static NSDictionary *ProQuotaInfoDict(void) {
    return @{
        @"tier": @"pro",
        @"remaining": @999999,
        @"resetAt": [NSNull null]
    };
}

static NSDictionary *ProQuotaUsageResponse(void) {
    return @{
        @"success": @YES,
        @"data": @{
            @"quota": ProQuotaInfoDict(),
            @"liveQuota": ProQuotaInfoDict()
        },
        @"meta": @{
            @"quota": ProQuotaInfoDict()
        }
    };
}

static NSDictionary *ProQuotaConfigResponse(void) {
    return @{
        @"success": @YES,
        @"data": @{
            @"tiers": @{
                @"free": @{ @"maxCalls": @999999 },
                @"trial": @{ @"maxCalls": @999999 },
                @"pro": @{ @"maxCalls": @999999 }
            },
            @"live": @{
                @"free": @{ @"maxCalls": @999999 },
                @"pro": @{ @"maxCalls": @999999 }
            }
        }
    };
}



/**
 * Phản hồi Subscriber giả lập RevenueCat v1 (Hiển thị PRO Lifetime trên toàn bộ UI)
 */
static NSDictionary *RevenueCatProSubscriberResponse(void) {
    NSString *futureDate = @"2099-12-31T23:59:59Z";
    NSString *pastDate   = @"2024-01-01T00:00:00Z";
    NSString *productId  = @"com.easycomix.pro.yearly";
    
    NSDictionary *entitlementInfo = @{
        @"expires_date": futureDate,
        @"grace_period_expires_date": [NSNull null],
        @"product_identifier": productId,
        @"purchase_date": pastDate
    };
    
    NSDictionary *subscriptionInfo = @{
        @"billing_issues_detected_at": [NSNull null],
        @"expires_date": futureDate,
        @"grace_period_expires_date": [NSNull null],
        @"is_sandbox": @NO,
        @"original_purchase_date": pastDate,
        @"ownership_type": @"PURCHASED",
        @"period_type": @"normal",
        @"purchase_date": pastDate,
        @"store": @"app_store",
        @"unsubscribe_detected_at": [NSNull null]
    };
    
    return @{
        @"request_date": @"2026-09-01T05:00:00Z",
        @"request_date_ms": @1788220800000,
        @"entitlement_verification": @1,
        @"schema_version": @"3",
        @"original_source": @"main",
        @"subscriber": @{
            @"original_app_user_id": @"$RCAnonymousID:easycomix_gemini_pro",
            @"original_application_version": @"1.0",
            @"original_purchase_date": pastDate,
            @"first_seen": pastDate,
            @"last_seen": @"2026-09-01T05:00:00Z",
            @"management_url": @"https://apps.apple.com/account/subscriptions",
            @"entitlements": @{
                @"EasyComix Pro": entitlementInfo,
                @"pro": entitlementInfo,
                @"premium": entitlementInfo,
                @"easycomix_pro": entitlementInfo,
                @"full_access": entitlementInfo
            },
            @"subscriptions": @{
                productId: subscriptionInfo,
                @"com.easycomix.pro.monthly": subscriptionInfo
            },
            @"non_subscriptions": @{},
            @"other_purchases": @{}
        }
    };
}

// Xử lý và tạo Response Dịch thuật cho cả Live và Classic
static void ProcessTranslatePayload(NSDictionary *payload, void (^completion)(NSDictionary *responseObject)) {
    NSString *source = PayloadString(payload, @[ @"sourceLanguage", @"sourceLang", @"srcLang" ], @"auto");
    NSString *target = PayloadString(payload, @[ @"targetLanguage", @"targetLang", @"tgtLang" ], @"vi");
    NSString *userContext = PayloadString(payload, @[ @"userContext", @"storyContext", @"context" ], @"");
    
    // A. DỊCH LIVE (hoặc Chapter Backend) gửi mảng 'bubbles' [{ "id": 0, "text": "..." }]
    id rawBubbles = payload[@"bubbles"];
    if ([rawBubbles isKindOfClass:[NSArray class]]) {
        NSArray *bubbles = (NSArray *)rawBubbles;
        if ([bubbles count] == 0) {
            completion(@{
                @"success": @YES,
                @"data": @{
                    @"translations": @[],
                    @"context": userContext ?: @""
                },
                @"meta": @{ @"quota": ProQuotaInfoDict() }
            });
            return;
        }
        
        NSMutableArray<NSString *> *textsToTranslate = [NSMutableArray array];
        for (id item in bubbles) {
            NSString *t = ExtractTextFromBubble(item);
            [textsToTranslate addObject:t];
        }
        
        NSUInteger keyCount = [GetGeminiKeyPool() count];
        CallGeminiTranslation(textsToTranslate, source, target, userContext, 0, MAX((NSUInteger)1, keyCount), ^(NSArray<NSString *> *translatedTexts) {
            NSMutableArray *translatedItems = [NSMutableArray array];
            for (NSUInteger i = 0; i < [bubbles count]; i++) {
                id item = bubbles[i];
                NSNumber *bubbleId = @(i);
                if ([item isKindOfClass:[NSDictionary class]] && item[@"id"] != nil) {
                    bubbleId = @([item[@"id"] longLongValue]);
                }
                NSString *transText = (i < [translatedTexts count]) ? translatedTexts[i] : @"";
                if ([transText length] == 0) {
                    transText = ExtractTextFromBubble(item);
                }
                [translatedItems addObject:@{
                    @"id": bubbleId,
                    @"text": transText ?: @""
                }];
            }
            
            NSMutableDictionary *dataDict = [NSMutableDictionary dictionary];
            dataDict[@"translations"] = translatedItems;
            if ([userContext length] > 0) {
                dataDict[@"context"] = userContext;
            }
            
            completion(@{
                @"success": @YES,
                @"data": dataDict,
                @"meta": @{ @"quota": ProQuotaInfoDict() }
            });
        });
        return;
    }

    // B. DỊCH CLASSIC / SINGLE PAGE / CHAPTER: gửi mảng 'texts' ["câu 1", "câu 2"]
    id rawTexts = payload[@"texts"];
    if ([rawTexts isKindOfClass:[NSArray class]]) {
        NSArray *texts = (NSArray *)rawTexts;
        if ([texts count] == 0) {
            completion(@{
                @"success": @YES,
                @"data": @{
                    @"translations": @[]
                },
                @"meta": @{ @"quota": ProQuotaInfoDict() }
            });
            return;
        }
        
        NSMutableArray<NSString *> *textsToTranslate = [NSMutableArray array];
        for (id item in texts) {
            NSString *t = ExtractTextFromBubble(item);
            [textsToTranslate addObject:t];
        }
        
        NSUInteger keyCount = [GetGeminiKeyPool() count];
        CallGeminiTranslation(textsToTranslate, source, target, userContext, 0, MAX((NSUInteger)1, keyCount), ^(NSArray<NSString *> *translatedTexts) {
            completion(@{
                @"success": @YES,
                @"data": @{
                    @"translations": translatedTexts ?: @[]
                },
                @"meta": @{ @"quota": ProQuotaInfoDict() }
            });
        });
        return;
    }

    // C. SINGLE TEXT:
    NSString *singleText = payload[@"text"] ?: @"";
    if ([singleText length] > 0) {
        NSUInteger keyCount = [GetGeminiKeyPool() count];
        CallGeminiTranslation(@[ singleText ], source, target, userContext, 0, MAX((NSUInteger)1, keyCount), ^(NSArray<NSString *> *translatedTexts) {
            completion(@{
                @"success": @YES,
                @"data": @{
                    @"translations": translatedTexts ?: @[]
                },
                @"meta": @{ @"quota": ProQuotaInfoDict() }
            });
        });
        return;
    }

    // D. FALLBACK RỖNG
    completion(@{
        @"success": @YES,
        @"data": @{
            @"translations": @[]
        },
        @"meta": @{ @"quota": ProQuotaInfoDict() }
    });
}

// =========================================================================
// NSURLPROTOCOL: INTERCEPT MỌI REQUEST CỦA EASYCOMIX
// =========================================================================

static NSString *const kEasyComixProtocolHandledKey = @"EasyComixGeminiProtocolHandled";

static BOOL IsGeminiInterceptRequest(NSURLRequest *request) {
    if ([NSURLProtocol propertyForKey:kEasyComixProtocolHandledKey inRequest:request]) {
        return NO;
    }
    NSURL *url = request.URL;
    NSString *host = [url.host lowercaseString] ?: @"";
    if ([host containsString:@"easycomix.app"] ||
        [host containsString:@"revenuecat.com"] ||
        [host containsString:@"8-lives-cat.io"]) {
        return YES;
    }
    return NO;
}

@interface EasyComixGeminiURLProtocol : NSURLProtocol
@property (atomic, assign) BOOL ecStopped;
@end

@implementation EasyComixGeminiURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return IsGeminiInterceptRequest(request);
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

static NSString *const kMockEd25519SignatureBase64 = @"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==";

static NSString *GetRequestSignatureNonce(NSURLRequest *request) {
    if (!request) return @"";
    NSString *nonce = [request valueForHTTPHeaderField:@"X-Signature-Nonce"];
    if (nonce.length > 0) return nonce;
    for (NSString *key in [request.allHTTPHeaderFields allKeys]) {
        if ([key caseInsensitiveCompare:@"X-Signature-Nonce"] == NSOrderedSame) {
            return request.allHTTPHeaderFields[key];
        }
    }
    return @"";
}

- (void)finishWithJSONObject:(NSDictionary *)object {
    if (self.ecStopped) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    
    NSString *reqNonce = GetRequestSignatureNonce(self.request);
    NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithDictionary:@{
        @"Content-Type": @"application/json; charset=utf-8",
        @"Access-Control-Allow-Origin": @"*",
        @"X-Signature": kMockEd25519SignatureBase64
    }];
    if (reqNonce.length > 0) {
        headers[@"X-Signature-Nonce"] = reqNonce;
    }
    
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                              statusCode:200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:headers];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)finishWithJSONArray:(NSArray *)array {
    if (self.ecStopped) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:array options:0 error:nil];
    
    NSString *reqNonce = GetRequestSignatureNonce(self.request);
    NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithDictionary:@{
        @"Content-Type": @"application/json; charset=utf-8",
        @"Access-Control-Allow-Origin": @"*",
        @"X-Signature": kMockEd25519SignatureBase64
    }];
    if (reqNonce.length > 0) {
        headers[@"X-Signature-Nonce"] = reqNonce;
    }
    
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                              statusCode:200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:headers];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)startLoading {
    NSString *host = [self.request.URL.host lowercaseString] ?: @"";
    NSString *path = self.request.URL.path ?: @"";
    LOG(@"NSURLProtocol intercepted: %@%@", host, path);

    // 0. REVENUECAT IN-APP PURCHASE FAKE (HIỂN THỊ PRO LIFETIME TRÊN UI)
    if ([host containsString:@"revenuecat.com"] || [host containsString:@"8-lives-cat.io"]) {
        if ([path containsString:@"/product_entitlement_mapping"]) {
            [self finishWithJSONObject:@{
                @"product_entitlement_mapping": @{
                    @"com.easycomix.pro.yearly": @{
                        @"product_identifier": @"com.easycomix.pro.yearly",
                        @"entitlements": @[ @"EasyComix Pro", @"pro", @"premium", @"easycomix_pro", @"full_access" ]
                    },
                    @"com.easycomix.pro.monthly": @{
                        @"product_identifier": @"com.easycomix.pro.monthly",
                        @"entitlements": @[ @"EasyComix Pro", @"pro", @"premium", @"easycomix_pro", @"full_access" ]
                    }
                }
            }];
            return;
        }
        [self finishWithJSONObject:RevenueCatProSubscriberResponse()];
        return;
    }

    // 2. USER PROFILE TRÊN EASYCOMIX BACKEND
    if ([path containsString:@"/user/profile"]) {
        [self finishWithJSONObject:@{
            @"success": @YES,
            @"data": @{
                @"id": @"00000000-0000-0000-0000-000000000001",
                @"userId": @"00000000-0000-0000-0000-000000000001",
                @"email": @"geminipro@easycomix.app",
                @"isPro": @YES,
                @"tier": @"pro",
                @"timezoneOffset": @7,
                @"createdAt": @"2024-01-01T00:00:00Z",
                @"updatedAt": @"2026-09-01T00:00:00Z"
            }
        }];
        return;
    }

    // 3. Cấu hình hạn mức (Quota Config)
    if ([path containsString:@"/quota/config"]) {
        [self finishWithJSONObject:ProQuotaConfigResponse()];
        return;
    }

    // 4. Hạn mức hiện tại (Quota Usage)
    if ([path containsString:@"/quota"]) {
        [self finishWithJSONObject:ProQuotaUsageResponse()];
        return;
    }

    // 5. Site Support (Bản 1.0.23 mới)
    if ([path containsString:@"/site-support"]) {
        [self finishWithJSONObject:@{
            @"success": @YES,
            @"data": @{
                @"version": @1,
                @"unsupportedDomains": @[]
            }
        }];
        return;
    }

    // 6. Quy tắc chặn quảng cáo (Ad Rules)
    if ([path containsString:@"/ad-rules"]) {
        [self finishWithJSONObject:@{
            @"success": @YES,
            @"data": @{
                @"version": @1,
                @"rules": @[]
            }
        }];
        return;
    }

    // 7. Whitelist & App Version Config
    if ([path containsString:@"/whitelist"]) {
        [self finishWithJSONObject:@{
            @"success": @YES,
            @"data": @{
                @"emails": @[ @"geminipro@easycomix.app" ]
            }
        }];
        return;
    }

    if ([path containsString:@"/app-version"]) {
        [self finishWithJSONObject:@{
            @"success": @YES,
            @"data": @{
                @"minVersion": @"1.0.0",
                @"latestVersion": @"1.0.23",
                @"whatsNew": @"EasyComix Gemini PRO Enabled"
            }
        }];
        return;
    }

    // 8. Sự kiện ghé thăm trang & phản hồi (Events / Feedback)
    if ([path containsString:@"/events/"] || [path containsString:@"/feedback"]) {
        [self finishWithJSONObject:@{
            @"success": @YES,
            @"data": @{}
        }];
        return;
    }

    // 9. Endpoint dịch thuật (/translate, /translate/chapter, /api/v1/translate,...)
    if ([path containsString:@"/translate"]) {
        NSData *bodyData = RequestBodyData(self.request);
        NSDictionary *payload = TranslationPayloadFromBodyData(bodyData);
        ProcessTranslatePayload(payload, ^(NSDictionary *responseObject) {
            [self finishWithJSONObject:responseObject];
        });
        return;
    }

    // Các request khác đến api.easycomix.app
    [self finishWithJSONObject:@{
        @"success": @YES,
        @"data": @{}
    }];
}

- (void)stopLoading {
    self.ecStopped = YES;
}

@end

// =========================================================================
// SWIZZLE TẤT CẢ CÁC CÁCH KHỞI TẠO NSURLSESSION TRONG SWIFT & OBJC
// =========================================================================

static void PrependGeminiProtocol(NSURLSessionConfiguration *configuration) {
    if (!configuration) return;
    NSArray *existing = configuration.protocolClasses ?: @[];
    if ([existing containsObject:[EasyComixGeminiURLProtocol class]]) return;
    configuration.protocolClasses = [@[ [EasyComixGeminiURLProtocol class] ] arrayByAddingObjectsFromArray:existing];
}

static void SwizzleMethod(Class cls, SEL origSel, SEL newSel) {
    Method origMethod = class_getInstanceMethod(cls, origSel);
    Method newMethod = class_getInstanceMethod(cls, newSel);
    if (origMethod && newMethod) {
        method_exchangeImplementations(origMethod, newMethod);
    }
}

static void SwizzleClassMethod(Class cls, SEL origSel, SEL newSel) {
    SwizzleMethod(object_getClass(cls), origSel, newSel);
}

@interface NSURLSessionConfiguration (EasyComixGeminiConfig)
+ (NSURLSessionConfiguration *)ec_defaultSessionConfiguration;
+ (NSURLSessionConfiguration *)ec_ephemeralSessionConfiguration;
@end

@implementation NSURLSessionConfiguration (EasyComixGeminiConfig)

+ (NSURLSessionConfiguration *)ec_defaultSessionConfiguration {
    NSURLSessionConfiguration *configuration = [self ec_defaultSessionConfiguration];
    PrependGeminiProtocol(configuration);
    return configuration;
}

+ (NSURLSessionConfiguration *)ec_ephemeralSessionConfiguration {
    NSURLSessionConfiguration *configuration = [self ec_ephemeralSessionConfiguration];
    PrependGeminiProtocol(configuration);
    return configuration;
}

@end

@interface NSURLSession (EasyComixGeminiSession)
+ (NSURLSession *)ec_sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
                                     delegate:(id<NSURLSessionDelegate>)delegate
                                delegateQueue:(NSOperationQueue *)queue;
+ (NSURLSession *)ec_sessionWithConfiguration:(NSURLSessionConfiguration *)configuration;
@end

@implementation NSURLSession (EasyComixGeminiSession)

+ (NSURLSession *)ec_sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
                                     delegate:(id<NSURLSessionDelegate>)delegate
                                delegateQueue:(NSOperationQueue *)queue {
    PrependGeminiProtocol(configuration);
    return [self ec_sessionWithConfiguration:configuration delegate:delegate delegateQueue:queue];
}

+ (NSURLSession *)ec_sessionWithConfiguration:(NSURLSessionConfiguration *)configuration {
    PrependGeminiProtocol(configuration);
    return [self ec_sessionWithConfiguration:configuration];
}

@end

@interface UIViewController (EasyComixHook)
@end

@implementation UIViewController (EasyComixHook)

- (void)hook_viewDidAppear:(BOOL)animated {
    [self hook_viewDidAppear:animated];
    
    if ([self isKindOfClass:NSClassFromString(@"GeminiSettingsViewController")]) {
        return;
    }
    
    AddFloatingButtonToWindow();
    
    NSString *className = NSStringFromClass([self class]);
    // Nếu màn hình Login hoặc Paywall hoặc TrialFlow hiển thị dạng sheet/modal đè lên reader, tự động đóng nó
    if ([className containsString:@"LoginView"] ||
        [className containsString:@"PaywallView"] ||
        [className containsString:@"TrialFlow"] ||
        [className containsString:@"PopupViewController"]) {
        LOG(@"Tự động bỏ qua màn hình chặn đăng nhập / mua gói: %@", className);
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

@end

// =========================================================================
// HOOK RUNTIME REVENUECAT & SUBSCRIPTION
// =========================================================================

static NSSet *Hook_activeSubscriptions(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return [NSSet setWithObjects:@"com.easycomix.pro.yearly", @"com.easycomix.pro.monthly", nil];
}

static NSSet *Hook_allPurchasedProductIdentifiers(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return [NSSet setWithObjects:@"com.easycomix.pro.yearly", @"com.easycomix.pro.monthly", nil];
}

static NSDate *Hook_latestExpirationDate(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return [NSDate dateWithTimeIntervalSince1970:4102444800]; // 2100-01-01
}

static BOOL Hook_isTrue(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return YES;
}

static NSInteger Hook_verification(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return 1; // Verified
}

static NSString *Hook_productIdentifier(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return @"com.easycomix.pro.yearly";
}

static NSString *Hook_entitlementIdentifier(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return @"EasyComix Pro";
}

static NSDate *Hook_distantFutureDate(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return [NSDate dateWithTimeIntervalSince1970:4102444800];
}

static void HookRevenueCatClasses(void) {
    NSArray *customerInfoClasses = @[ @"RCCustomerInfo", @"_TtC10RevenueCat12CustomerInfo" ];
    for (NSString *className in customerInfoClasses) {
        Class cls = NSClassFromString(className);
        if (cls) {
            class_replaceMethod(cls, sel_registerName("activeSubscriptions"), (IMP)Hook_activeSubscriptions, "@@:");
            class_replaceMethod(cls, sel_registerName("allPurchasedProductIdentifiers"), (IMP)Hook_allPurchasedProductIdentifiers, "@@:");
            class_replaceMethod(cls, sel_registerName("latestExpirationDate"), (IMP)Hook_latestExpirationDate, "@@:");
            class_replaceMethod(cls, sel_registerName("entitlementVerification"), (IMP)Hook_verification, "q@:");
            LOG(@"Đã hook %@ (activeSubscriptions, allPurchasedProductIdentifiers, latestExpirationDate, entitlementVerification)", className);
        }
    }
    
    NSArray *entitlementInfoClasses = @[ @"RCEntitlementInfo", @"_TtC10RevenueCat15EntitlementInfo" ];
    for (NSString *className in entitlementInfoClasses) {
        Class cls = NSClassFromString(className);
        if (cls) {
            class_replaceMethod(cls, sel_registerName("isActive"), (IMP)Hook_isTrue, "B@:");
            class_replaceMethod(cls, sel_registerName("willRenew"), (IMP)Hook_isTrue, "B@:");
            class_replaceMethod(cls, sel_registerName("isActiveInAnyEnvironment"), (IMP)Hook_isTrue, "B@:");
            class_replaceMethod(cls, sel_registerName("isActiveInCurrentEnvironment"), (IMP)Hook_isTrue, "B@:");
            class_replaceMethod(cls, sel_registerName("expirationDate"), (IMP)Hook_distantFutureDate, "@@:");
            class_replaceMethod(cls, sel_registerName("verification"), (IMP)Hook_verification, "q@:");
            class_replaceMethod(cls, sel_registerName("productIdentifier"), (IMP)Hook_productIdentifier, "@@:");
            class_replaceMethod(cls, sel_registerName("identifier"), (IMP)Hook_entitlementIdentifier, "@@:");
            LOG(@"Đã hook %@ (isActive, willRenew, expirationDate, verification, productIdentifier, identifier)", className);
        }
    }
}


// =========================================================================
// DIRECT GOT PATCHING: Bypass CryptoKit isValidSignature (Ed25519)
// =========================================================================
// EasyComix 1.0.23 sử dụng LC_DYLD_CHAINED_FIXUPS (iOS 15+ / Xcode 14+)
// khiến indirect symbol table rỗng (nindirectsyms=0).
// Fishhook KHÔNG THỂ hoạt động vì nó dựa vào bảng này.
// Giải pháp: ghi trực tiếp vào GOT entry tại địa chỉ ảo đã biết.
//
// Stub CryptoKit isValidSignature:
//   0x10040bef4: adrp x16, #0x100516000
//   0x10040bef8: ldr  x16, [x16, #0xaa8]
//   0x10040befc: br   x16
// GOT entry: virtual 0x100516aa8 (trong __DATA_CONST,__got)
// =========================================================================

// Hook function: luôn trả về true (1) cho isValidSignature
// ARM64 calling convention: return value trong w0
static bool Hook_CryptoKit_isValidSignature(void) {
    return true;
}

// Địa chỉ ảo (virtual address) của GOT entry cho isValidSignature
// Được trích xuất từ stub tại 0x10040bef4 trong Mach-O binary
#define CRYPTOKIT_ISVALIDSIGNATURE_GOT_VA 0x100516aa8ULL

static void PatchGOTEntry(uintptr_t got_virtual_addr, void *new_func_ptr) {
    // Tìm main executable image (index 0 = dyld, thường main app là image chứa đường dẫn app)
    uint32_t image_count = _dyld_image_count();
    intptr_t slide = 0;
    BOOL found = NO;
    
    for (uint32_t i = 0; i < image_count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "EasyComix")) {
            slide = _dyld_get_image_vmaddr_slide(i);
            found = YES;
            LOG(@"[GOT Patch] Tìm thấy EasyComix image tại index %u, ASLR slide = 0x%lx", i, (unsigned long)slide);
            break;
        }
    }
    
    if (!found) {
        // Fallback: thử image index 0 (thường là main executable)
        slide = _dyld_get_image_vmaddr_slide(0);
        LOG(@"[GOT Patch] Không tìm thấy EasyComix image, dùng slide index 0 = 0x%lx", (unsigned long)slide);
    }
    
    // Tính địa chỉ runtime của GOT entry
    void **got_entry_ptr = (void **)(got_virtual_addr + (uintptr_t)slide);
    
    // Căn chỉnh theo page boundary (16KB trên iOS ARM64)
    size_t page_size = (size_t)sysconf(_SC_PAGESIZE);
    if (page_size == 0) page_size = 16384;
    
    uintptr_t page_start = (uintptr_t)got_entry_ptr & ~(page_size - 1);
    size_t page_len = page_size * 2; // Bao phủ 2 page đề phòng entry nằm giữa ranh giới
    
    // Mở khóa bộ nhớ __DATA_CONST bằng vm_protect + VM_PROT_COPY
    kern_return_t kr = vm_protect(
        mach_task_self(),
        (vm_address_t)page_start,
        (vm_size_t)page_len,
        0,
        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY
    );
    
    if (kr != KERN_SUCCESS) {
        LOG(@"[GOT Patch] vm_protect FAILED (kr=%d), thử mprotect fallback...", kr);
        int mp = mprotect((void *)page_start, page_len, PROT_READ | PROT_WRITE);
        if (mp != 0) {
            LOG(@"[GOT Patch] mprotect cũng FAILED (errno=%d). Không thể patch GOT!", errno);
            return;
        }
    }
    
    // Lưu giá trị cũ và ghi đè bằng hook function
    void *old_value = *got_entry_ptr;
    *got_entry_ptr = new_func_ptr;
    
    // Khôi phục quyền truy cập (read-only)
    vm_protect(
        mach_task_self(),
        (vm_address_t)page_start,
        (vm_size_t)page_len,
        0,
        VM_PROT_READ
    );
    
    LOG(@"[GOT Patch] Đã patch GOT tại %p: %p -> %p", got_entry_ptr, old_value, new_func_ptr);
}

// =========================================================================
// KHỞI TẠO TWEAK: GỠ BỎ GIỚI HẠN & KÍCH HOẠT PRO VĨNH VIỄN
// =========================================================================

__attribute__((constructor))
static void InitEasyComixGeminiHook(void) {
    LOG(@"EasyComix Gemini PRO Hook initialized. Model: %@", GetSavedGeminiModel());
    
    // 1. BYPASS CHỮ KÝ ED25519: Patch trực tiếp GOT entry của CryptoKit isValidSignature
    //    Binary 1.0.23 dùng LC_DYLD_CHAINED_FIXUPS -> fishhook không hoạt động
    //    Phải ghi trực tiếp vào GOT entry tại virtual address 0x100516aa8
    PatchGOTEntry(CRYPTOKIT_ISVALIDSIGNATURE_GOT_VA, (void *)Hook_CryptoKit_isValidSignature);
    LOG(@"Đã bypass CryptoKit isValidSignature bằng Direct GOT Patch");

    // 2. Tự động xóa cache hạn mức cũ trong UserDefaults của app
    NSDictionary *defaultsDict = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    for (NSString *key in [defaultsDict allKeys]) {
        if ([key containsString:@"quota"] || [key containsString:@"Quota"] || [key containsString:@"limit"] || [key containsString:@"Tier"]) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
        }
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    // 3. Xóa cache RevenueCat cũ bị lỗi verification để nạp mới
    NSUserDefaults *rcDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.revenuecat.user_defaults"];
    if (rcDefaults) {
        NSDictionary *rcDict = [rcDefaults dictionaryRepresentation];
        for (NSString *k in [rcDict allKeys]) {
            if ([k containsString:@"purchaserInfo"] || [k containsString:@"PurchaserInfo"]) {
                [rcDefaults removeObjectForKey:k];
            }
        }
        [rcDefaults synchronize];
    }
    
    // 4. Hook RevenueCat Runtime
    HookRevenueCatClasses();
    
    // 5. Đăng ký NSURLProtocol
    [NSURLProtocol registerClass:[EasyComixGeminiURLProtocol class]];
    
    // 6. Swizzle các hàm tạo session configuration & session instance
    SwizzleClassMethod([NSURLSessionConfiguration class],
                       @selector(defaultSessionConfiguration),
                       @selector(ec_defaultSessionConfiguration));
    SwizzleClassMethod([NSURLSessionConfiguration class],
                       @selector(ephemeralSessionConfiguration),
                       @selector(ec_ephemeralSessionConfiguration));
    SwizzleClassMethod([NSURLSession class],
                       @selector(sessionWithConfiguration:delegate:delegateQueue:),
                       @selector(ec_sessionWithConfiguration:delegate:delegateQueue:));
    SwizzleClassMethod([NSURLSession class],
                       @selector(sessionWithConfiguration:),
                       @selector(ec_sessionWithConfiguration:));
                  
    // 7. Gắn nút cài đặt nổi trên UI & Tự động đóng modal chặn
    SwizzleMethod([UIViewController class],
                  @selector(viewDidAppear:),
                  @selector(hook_viewDidAppear:));
}
