#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

/**
 * EasyComix Gemini Tweak (Dylib) - Phiên bản Key Pool & Modern Models
 * Tự động xoay vòng đa API Key (Key Rotation khi gặp lỗi 429/403)
 * Hỗ trợ các Model mới: gemini-2.5-flash-lite (mặc định), gemini-3.5-flash-lite, gemini-2.5-flash, gemini-3.6-flash, gemini-3.7-flash
 */

#define LOG(fmt, ...) NSLog(@"[EasyComixGemini] " fmt, ##__VA_ARGS__)

static NSString *const kGeminiKeysPref  = @"EasyComix_Gemini_Key_Pool";
static NSString *const kGeminiModelPref = @"EasyComix_Gemini_Model_Name";
static NSUInteger sCurrentKeyIndex = 0;

// =========================================================================
// QUẢN LÝ KEY POOL (XOAY VÒNG KEY TỰ ĐỘNG)
// =========================================================================

static NSArray<NSString *> *GetGeminiKeyPool(void) {
    NSString *rawKeys = [[NSUserDefaults standardUserDefaults] stringForKey:kGeminiKeysPref];
    if (!rawKeys || [rawKeys length] == 0) {
        return [NSArray array];
    }
    
    NSArray *components = [rawKeys componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\n,"]];
    NSMutableArray *validKeys = [NSMutableArray array];
    
    for (NSString *k in components) {
        NSString *trimmed = [k stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([trimmed length] > 0) {
            [validKeys addObject:trimmed];
        }
    }
    return validKeys;
}

static NSString *GetActiveGeminiKey(void) {
    NSArray *keys = GetGeminiKeyPool();
    if ([keys count] == 0) return @"";
    return keys[sCurrentKeyIndex % [keys count]];
}

static void RotateToNextKey(void) {
    NSArray *keys = GetGeminiKeyPool();
    if ([keys count] > 1) {
        sCurrentKeyIndex = (sCurrentKeyIndex + 1) % [keys count];
        LOG(@"Đã tự động xoay sang Key #%lu/%lu", (unsigned long)(sCurrentKeyIndex + 1), (unsigned long)[keys count]);
    }
}

static NSString *GetSavedGeminiModel(void) {
    NSString *model = [[NSUserDefaults standardUserDefaults] stringForKey:kGeminiModelPref];
    if (!model || [model length] == 0) {
        return @"gemini-2.5-flash-lite";
    }
    return [model stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// =========================================================================
// GIAO DIỆN CÀI ĐẶT: POPUP NHẬP NHIỀU KEY & NÚT NỔI
// =========================================================================

static void ShowGeminiSettingsPopup(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
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
        
        NSArray *currentKeys = GetGeminiKeyPool();
        NSString *currentKeysText = [[NSUserDefaults standardUserDefaults] stringForKey:kGeminiKeysPref] ?: @"";
        NSString *message = [NSString stringWithFormat:@"Đang có %lu Key trong Pool.\n(Dán nhiều Key, mỗi dòng 1 Key để tự động xoay khi hết hạn mức)", (unsigned long)[currentKeys count]];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🤖 Gemini Key Pool & Model"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
            textField.placeholder = @"Dán danh sách API Key (mỗi dòng 1 key)...";
            textField.text = currentKeysText;
            textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        
        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
            textField.placeholder = @"Model: gemini-2.5-flash-lite (mặc định)";
            textField.text = GetSavedGeminiModel();
            textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        
        UIAlertAction *saveAction = [UIAlertAction actionWithTitle:@"Lưu Cấu Hình"
                                                             style:UIAlertActionStyleDefault
                                                           handler:^(UIAlertAction * _Nonnull action) {
            NSString *newKeys = alert.textFields[0].text;
            NSString *newModel = alert.textFields[1].text;
            
            if (newKeys) {
                [[NSUserDefaults standardUserDefaults] setObject:[newKeys stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] forKey:kGeminiKeysPref];
            }
            if (newModel && [newModel length] > 0) {
                [[NSUserDefaults standardUserDefaults] setObject:[newModel stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] forKey:kGeminiModelPref];
            } else {
                [[NSUserDefaults standardUserDefaults] setObject:@"gemini-2.5-flash-lite" forKey:kGeminiModelPref];
            }
            [[NSUserDefaults standardUserDefaults] synchronize];
            sCurrentKeyIndex = 0;
            LOG(@"Đã cập nhật cấu hình: %lu keys, Model: %@", (unsigned long)[GetGeminiKeyPool() count], GetSavedGeminiModel());
        }];
        
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Đóng"
                                                               style:UIAlertActionStyleCancel
                                                             handler:nil];
        
        [alert addAction:saveAction];
        [alert addAction:cancelAction];
        
        [topVC presentViewController:alert animated:YES completion:nil];
    });
}

// Nút nổi kéo thả trên màn hình
@interface GeminiFloatingButton : UIButton
@end

@implementation GeminiFloatingButton

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.55 blue:1.0 alpha:0.9];
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
                if ([w isKeyWindow]) {
                    keyWindow = w;
                    break;
                }
            }
            if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
            if (keyWindow) {
                GeminiFloatingButton *btn = [[GeminiFloatingButton alloc] initWithFrame:CGRectMake(20, 150, 50, 50)];
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
// XỬ LÝ CHẶN MẠNG & DỊCH THUẬT VỚI CƠ CHẾ XOAY VÒNG KEY
// =========================================================================

@interface EasyComixURLProtocol : NSURLProtocol <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSessionDataTask *task;
@end

@interface EasyComixURLProtocol ()
- (void)executeGeminiRequestWithTexts:(NSArray *)texts sourceLang:(NSString *)srcLang targetLang:(NSString *)tgtLang attemptNo:(NSUInteger)attempt maxTries:(NSUInteger)maxTries;
- (void)sendJsonResponse:(NSDictionary *)jsonDict statusCode:(NSInteger)code;
- (NSData *)readDataFromStream:(NSInputStream *)stream;
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
    
    // 1. Quota Endpoint -> Trả về hạn mức 999,999 với tier 'free'
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
    
    // 2. Translation Endpoint
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
        
        if (!texts || [texts count] == 0) {
            NSDictionary *emptyResp = @{@"success": @YES, @"data": @{@"translations": @[]}, @"meta": @{@"quota": @{@"tier": @"free", @"remaining": @999999, @"resetAt": @"2099-01-01T00:00:00.000Z"}}};
            [self sendJsonResponse:emptyResp statusCode:200];
            return;
        }
        
        NSArray *keyPool = GetGeminiKeyPool();
        if ([keyPool count] == 0) {
            ShowGeminiSettingsPopup();
            NSDictionary *resp = @{@"success": @YES, @"data": @{@"translations": texts}, @"meta": @{@"quota": @{@"tier": @"free", @"remaining": @999999, @"resetAt": @"2099-01-01T00:00:00.000Z"}}};
            [self sendJsonResponse:resp statusCode:200];
            return;
        }
        
        [self executeGeminiRequestWithTexts:texts
                                 sourceLang:srcLang
                                 targetLang:tgtLang
                                  attemptNo:0
                                   maxTries:[keyPool count]];
    }
}

- (void)stopLoading {
    [self.task cancel];
}

#pragma mark - Thực thi Gemini với Key Rotation

- (void)executeGeminiRequestWithTexts:(NSArray *)texts
                           sourceLang:(NSString *)srcLang
                           targetLang:(NSString *)tgtLang
                            attemptNo:(NSUInteger)attempt
                             maxTries:(NSUInteger)maxTries {
    
    NSString *currentKey = GetActiveGeminiKey();
    NSString *model = GetSavedGeminiModel();
    
    NSError *error;
    NSData *textsJsonData = [NSJSONSerialization dataWithJSONObject:texts options:0 error:&error];
    NSString *textsJsonString = [[NSString alloc] initWithData:textsJsonData encoding:NSUTF8StringEncoding];
    
    NSString *prompt = [NSString stringWithFormat:
        @"Bạn là dịch giả truyện tranh (Manga/Manhwa/Comic) chuyên nghiệp.\n"
        @"Hãy dịch danh sách các câu thoại sau từ ngôn ngữ '%@' sang '%@'.\n"
        @"Quy tắc:\n"
        @"- Dịch mượt mà, cảm xúc tự nhiên, đúng ngữ cảnh thoại truyện tranh.\n"
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
        model, currentKey];
    
    NSMutableURLRequest *geminiReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:geminiEndpoint]];
    [geminiReq setHTTPMethod:@"POST"];
    [geminiReq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [geminiReq setHTTPBody:[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil]];
    [NSURLProtocol setProperty:@YES forKey:@"EasyComixHandled" inRequest:geminiReq];
    
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    
    [[session dataTaskWithRequest:geminiReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *netError) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSInteger statusCode = httpResponse.statusCode;
        
        BOOL isKeyError = (statusCode == 429 || statusCode == 400 || statusCode == 401 || statusCode == 403);
        
        if ((isKeyError || netError) && attempt < maxTries - 1) {
            LOG(@"Key hiện tại bị lỗi (HTTP %ld). Đang tự động chuyển sang Key tiếp theo...", (long)statusCode);
            RotateToNextKey();
            [self executeGeminiRequestWithTexts:texts
                                     sourceLang:srcLang
                                     targetLang:tgtLang
                                      attemptNo:attempt + 1
                                       maxTries:maxTries];
            return;
        }
        
        NSArray *translatedList = nil;
        if (!netError && data && statusCode == 200) {
            NSDictionary *geminiRes = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *rawText = geminiRes[@"candidates"][0][@"content"][@"parts"][0][@"text"];
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
                }
            }
        }
        
        if (!translatedList || [translatedList count] == 0) {
            translatedList = texts;
        }
        
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
    LOG(@"EasyComix Gemini Hook Loaded with Key Pool & Modern Models!");
    
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
