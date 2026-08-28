#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

/**
 * EasyComix Gemini Tweak (Dylib) with Settings Popup & Floating Button
 * Tự động chặn toàn bộ request dịch và quota của EasyComix và chuyển hướng sang Google Gemini API.
 */

#define LOG(fmt, ...) NSLog(@"[EasyComixGemini] " fmt, ##__VA_ARGS__)

static NSString *const kGeminiKeyPref   = @"EasyComix_Gemini_API_Key";
static NSString *const kGeminiModelPref = @"EasyComix_Gemini_Model_Name";

static NSString *GetSavedGeminiKey(void) {
    NSString *key = [[NSUserDefaults standardUserDefaults] stringForKey:kGeminiKeyPref];
    if (!key || key.length == 0) {
        return @"";
    }
    return [key stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *GetSavedGeminiModel(void) {
    NSString *model = [[NSUserDefaults standardUserDefaults] stringForKey:kGeminiModelPref];
    if (!model || model.length == 0) {
        return @"gemini-1.5-flash";
    }
    return [model stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// =========================================================================
// GIAO DIỆN CÀI ĐẶT: POPUP NHẬP KEY & NÚT NỔI (FLOATING BUTTON)
// =========================================================================

static void ShowGeminiSettingsPopup(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) {
                keyWindow = w;
                break;
            }
        }
        if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
        UIViewController *topVC = keyWindow.rootViewController;
        while (topVC.presentedViewController) {
            topVC = topVC.presentedViewController;
        }
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🤖 Cài đặt Gemini API"
                                                                       message:@"Nhập Google Gemini API Key để dịch truyện không giới hạn:"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
            textField.placeholder = @"Dán Gemini API Key vào đây...";
            textField.text = GetSavedGeminiKey();
            textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        
        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
            textField.placeholder = @"Tên Model (mặc định: gemini-1.5-flash)";
            textField.text = GetSavedGeminiModel();
            textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        
        UIAlertAction *saveAction = [UIAlertAction actionWithTitle:@"Lưu Cấu Hình"
                                                             style:UIAlertActionStyleDefault
                                                           handler:^(UIAlertAction * _Nonnull action) {
            NSString *newKey = alert.textFields[0].text;
            NSString *newModel = alert.textFields[1].text;
            
            if (newKey) {
                [[NSUserDefaults standardUserDefaults] setObject:[newKey stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] forKey:kGeminiKeyPref];
            }
            if (newModel && newModel.length > 0) {
                [[NSUserDefaults standardUserDefaults] setObject:[newModel stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] forKey:kGeminiModelPref];
            } else {
                [[NSUserDefaults standardUserDefaults] setObject:@"gemini-1.5-flash" forKey:kGeminiModelPref];
            }
            [[NSUserDefaults standardUserDefaults] synchronize];
            LOG(@"Đã lưu API Key mới: %@", GetSavedGeminiKey());
        }];
        
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Đóng"
                                                               style:UIAlertActionStyleCancel
                                                             handler:nil];
        
        [alert addAction:saveAction];
        [alert addAction:cancelAction];
        
        [topVC presentViewController:alert animated:YES completion:nil];
    });
}

// Nút nổi để người dùng có thể bấm vào đổi key bất kỳ lúc nào
@interface GeminiFloatingButton : UIButton
@end

@implementation GeminiFloatingButton

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:1.0 alpha:0.85];
        [self setTitle:@"🤖 Key" forState:UIControlStateNormal];
        self.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        self.layer.cornerRadius = frame.size.width / 2.0;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        self.layer.shadowRadius = 4;
        self.layer.shadowOpacity = 0.3;
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIWindow *keyWindow = nil;
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (w.isKeyWindow) {
                    keyWindow = w;
                    break;
                }
            }
            if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
            if (keyWindow) {
                GeminiFloatingButton *btn = [[GeminiFloatingButton alloc] initWithFrame:CGRectMake(20, 150, 50, 50)];
                [keyWindow addSubview:btn];
                [keyWindow bringSubviewToFront:btn];
                
                // Nếu chưa có key thì hiện popup nhắc nhập key ngay lần đầu mở app
                if (GetSavedGeminiKey().length == 0) {
                    ShowGeminiSettingsPopup();
                }
            }
        });
    });
}

// =========================================================================
// XỬ LÝ CHẶN MẠNG & DỊCH THUẬT BẰNG GEMINI API
// =========================================================================

@interface EasyComixURLProtocol : NSURLProtocol <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSessionDataTask *task;
@end

@implementation EasyComixURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *urlString = request.URL.absoluteString;
    if (!urlString) return NO;
    
    if ([NSURLProtocol propertyForKey:@"EasyComixHandled" inRequest:request]) {
        return NO;
    }
    
    if ([urlString containsString:@"api.easycomix.app"] &&
        ([urlString containsString:@"/translate"] || [urlString containsString:@"/quota"])) {
        return YES;
    }
    
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *handledRequest = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"EasyComixHandled" inRequest:handledRequest];
    
    NSString *urlString = self.request.URL.absoluteString;
    LOG(@"Interception: %@", urlString);
    
    // 1. Endpoint Quota -> Trả về hợp lệ với tier 'free' để không bị lỗi decode Enum
    if ([urlString containsString:@"/quota"]) {
        NSDictionary *fakeQuota = @{
            @"success": @YES,
            @"data": @{
                @"tier": @"free",
                @"remaining": @999999,
                @"resetAt": @"2099-01-01T00:00:00.000Z"
            }
        };
        [self sendJsonResponse:fakeQuota statusCode:200];
        return;
    }
    
    // 2. Endpoint Dịch thuật
    if ([urlString containsString:@"/translate"]) {
        NSData *bodyData = self.request.HTTPBody;
        if (!bodyData && self.request.HTTPBodyStream) {
            bodyData = [self readDataFromStream:self.request.HTTPBodyStream];
        }
        
        if (!bodyData) {
            NSDictionary *emptyResp = @{@"success": @YES, @"data": @{@"translations": @[]}, @"meta": @{@"quota": @{@"tier": @"free", @"remaining": @999999, @"resetAt": @"2099-01-01T00:00:00.000Z"}}};
            [self sendJsonResponse:emptyResp statusCode:200];
            return;
        }
        
        NSError *jsonError = nil;
        NSDictionary *bodyJson = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:&jsonError];
        NSArray *texts = bodyJson[@"texts"];
        NSString *srcLang = bodyJson[@"sourceLanguage"] ?: @"auto";
        NSString *tgtLang = bodyJson[@"targetLanguage"] ?: @"vi";
        
        if (!texts || texts.count == 0) {
            NSDictionary *emptyResp = @{@"success": @YES, @"data": @{@"translations": @[]}, @"meta": @{@"quota": @{@"tier": @"free", @"remaining": @999999, @"resetAt": @"2099-01-01T00:00:00.000Z"}}};
            [self sendJsonResponse:emptyResp statusCode:200];
            return;
        }
        
        // Kiểm tra xem đã có API Key chưa
        NSString *apiKey = GetSavedGeminiKey();
        if (apiKey.length == 0) {
            ShowGeminiSettingsPopup();
            // Trả về text gốc tạm thời
            NSDictionary *resp = @{@"success": @YES, @"data": @{@"translations": texts}, @"meta": @{@"quota": @{@"tier": @"free", @"remaining": @999999, @"resetAt": @"2099-01-01T00:00:00.000Z"}}};
            [self sendJsonResponse:resp statusCode:200];
            return;
        }
        
        [self callGeminiWithTexts:texts sourceLang:srcLang targetLang:tgtLang apiKey:apiKey];
    }
}

- (void)stopLoading {
    [self.task cancel];
}

#pragma mark - Gọi Gemini API

- (void)callGeminiWithTexts:(NSArray *)texts sourceLang:(NSString *)srcLang targetLang:(NSString *)tgtLang apiKey:(NSString *)apiKey {
    NSString *model = GetSavedGeminiModel();
    
    NSError *error;
    NSData *textsJsonData = [NSJSONSerialization dataWithJSONObject:texts options:0 error:&error];
    NSString *textsJsonString = [[NSString alloc] initWithData:textsJsonData encoding:NSUTF8StringEncoding];
    
    NSString *prompt = [NSString stringWithFormat:
        @"Bạn là dịch giả truyện tranh (Manga/Manhwa/Comic) chuyên nghiệp.\n"
        @"Hãy dịch danh sách các câu thoại sau từ ngôn ngữ '%@' sang '%@'.\n"
        @"Quy tắc:\n"
        @"- Dịch mượt mà, cảm xúc tự nhiên, đúng ngữ cảnh truyện tranh.\n"
        @"- Trả về DUY NHẤT một JSON Array mảng chuỗi theo đúng thứ tự (ví dụ: [\"câu 1\", \"câu 2\"]).\n"
        @"- KHÔNG thêm bất kỳ markdown hoặc giải thích nào.\n\n"
        @"Danh sách:\n%@", srcLang, tgtLang, textsJsonString];
    
    NSDictionary *payload = @{
        @"contents": @[
            @{ @"parts": @[ @{ @"text": prompt } ] }
        ],
        @"generationConfig": @{
            @"response_mime_type": @"application/json"
        }
    };
    
    NSString *geminiEndpoint = [NSString stringWithFormat:
        @"https://generativelanguage.googleapis.com/v1beta/models/%@:generateContent?key=%@",
        model, apiKey];
    
    NSMutableURLRequest *geminiReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:geminiEndpoint]];
    [geminiReq setHTTPMethod:@"POST"];
    [geminiReq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [geminiReq setHTTPBody:[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil]];
    [NSURLProtocol setProperty:@YES forKey:@"EasyComixHandled" inRequest:geminiReq];
    
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    
    [[session dataTaskWithRequest:geminiReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *netError) {
        NSArray *translatedList = nil;
        if (!netError && data) {
            NSDictionary *geminiRes = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *rawText = geminiRes[@"candidates"][0][@"content"][@"parts"][0][@"text"];
            if (rawText) {
                // Xử lý loại bỏ markdown ```json nếu có
                NSString *cleanText = [rawText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if ([cleanText hasPrefix:@"```json"]) {
                    cleanText = [cleanText substringFromIndex:7];
                } else if ([cleanText hasPrefix:@"```"]) {
                    cleanText = [cleanText substringFromIndex:3];
                }
                if ([cleanText hasSuffix:@"```"]) {
                    cleanText = [cleanText substringToIndex:cleanText.length - 3];
                }
                cleanText = [cleanText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                
                NSData *cleanData = [cleanText dataUsingEncoding:NSUTF8StringEncoding];
                id parsed = [NSJSONSerialization JSONObjectWithData:cleanData options:0 error:nil];
                if ([parsed isKindOfClass:[NSArray class]]) {
                    translatedList = (NSArray *)parsed;
                }
            }
        }
        
        // Nếu lỗi Gemini thì giữ nguyên text gốc để không bị crash giao diện
        if (!translatedList || translatedList.count == 0) {
            translatedList = texts;
        }
        
        // Đóng gói JSON chuẩn 100% theo đúng cấu trúc EasyComix
        NSDictionary *finalResponse = @{
            @"success": @YES,
            @"data": @{
                @"translations": translatedList
            },
            @"meta": @{
                @"quota": @{
                    @"tier": @"free",
                    @"remaining": @999999,
                    @"resetAt": @"2099-01-01T00:00:00.000Z"
                }
            }
        };
        
        [self sendJsonResponse:finalResponse statusCode:200];
    }] resume];
}

- (void)sendJsonResponse:(NSDictionary *)jsonDict statusCode:(NSInteger)code {
    NSData *data = [NSJSONSerialization dataWithJSONObject:jsonDict options:0 error:nil];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                              statusCode:code
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:@{
                                                                @"Content-Type": @"application/json; charset=utf-8",
                                                                @"Access-Control-Allow-Origin": @"*"
                                                            }];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}

- (NSData *)readDataFromStream:(NSInputStream *)stream {
    [stream open];
    NSMutableData *data = [NSMutableData data];
    uint8_t buffer[1024];
    NSInteger len = 0;
    while ([stream hasBytesAvailable] && (len = [stream read:buffer maxLength:sizeof(buffer)]) > 0) {
        [data appendBytes:buffer length:len];
    }
    [stream close];
    return data;
}

@end

// =========================================================================
// SWIZZLING ĐỂ TẤT CẢ NSURLSESSION ĐỀU CHẠY QUA PROTOCOL & HIỆN NÚT CÀI ĐẶT
// =========================================================================

static void SwizzleMethod(Class cls, SEL origSel, SEL newSel) {
    Method origMethod = class_getClassMethod(cls, origSel);
    Method newMethod = class_getClassMethod(cls, newSel);
    if (!origMethod || !newMethod) {
        origMethod = class_getInstanceMethod(cls, origSel);
        newMethod = class_getInstanceMethod(cls, newSel);
    }
    if (origMethod && newMethod) {
        method_exchangeImplementations(origMethod, newMethod);
    }
}

@interface NSURLSessionConfiguration (EasyComixHook)
@end

@implementation NSURLSessionConfiguration (EasyComixHook)

+ (NSURLSessionConfiguration *)hook_defaultSessionConfiguration {
    NSURLSessionConfiguration *config = [self hook_defaultSessionConfiguration];
    NSMutableArray *protocols = [config.protocolClasses mutableCopy] ?: [NSMutableArray array];
    if (![protocols containsObject:[EasyComixURLProtocol class]]) {
        [protocols insertObject:[EasyComixURLProtocol class] atIndex:0];
    }
    config.protocolClasses = protocols;
    return config;
}

+ (NSURLSessionConfiguration *)hook_ephemeralSessionConfiguration {
    NSURLSessionConfiguration *config = [self hook_ephemeralSessionConfiguration];
    NSMutableArray *protocols = [config.protocolClasses mutableCopy] ?: [NSMutableArray array];
    if (![protocols containsObject:[EasyComixURLProtocol class]]) {
        [protocols insertObject:[EasyComixURLProtocol class] atIndex:0];
    }
    config.protocolClasses = protocols;
    return config;
}

@end

// Hook UIViewController viewDidAppear để gắn nút cài đặt vào màn hình
@interface UIViewController (EasyComixHook)
@end

@implementation UIViewController (EasyComixHook)

- (void)hook_viewDidAppear:(BOOL)animated {
    [self hook_viewDidAppear:animated];
    AddFloatingButtonToWindow();
}

@end

__attribute__((constructor))
static void InitEasyComixGeminiHook(void) {
    LOG(@"EasyComix Gemini Hook Loaded successfully with Settings UI!");
    
    [NSURLProtocol registerClass:[EasyComixURLProtocol class]];
    
    SwizzleMethod([NSURLSessionConfiguration class],
                  @selector(defaultSessionConfiguration),
                  @selector(hook_defaultSessionConfiguration));
                  
    SwizzleMethod([NSURLSessionConfiguration class],
                  @selector(ephemeralSessionConfiguration),
                  @selector(hook_ephemeralSessionConfiguration));
                  
    SwizzleMethod([UIViewController class],
                  @selector(viewDidAppear:),
                  @selector(hook_viewDidAppear:));
}
