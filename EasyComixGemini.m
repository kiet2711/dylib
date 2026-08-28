#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

/**
 * EasyComix Gemini Tweak (Dylib) - Direct NSURLSession Swizzling
 * Bắt trực tiếp HTTPBody không qua NSURLProtocol (tránh lỗi nil body của iOS)
 * Tự động xoay vòng đa API Key (Key Rotation) & Tự động thử lại Model thay thế
 */

#define LOG(fmt, ...) NSLog(@"[EasyComixGemini] " fmt, ##__VA_ARGS__)

static NSString *const kGeminiKeysPref  = @"EasyComix_Gemini_Key_Pool";
static NSString *const kGeminiModelPref = @"EasyComix_Gemini_Model_Name";
static NSUInteger sCurrentKeyIndex = 0;

// =========================================================================
// QUẢN LÝ KEY POOL & MODEL
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
        return @"gemini-2.5-flash"; // Model phổ biến & ổn định nhất
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
            textField.placeholder = @"Model: gemini-2.5-flash (hoặc gemini-2.5-flash-lite)";
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
                [[NSUserDefaults standardUserDefaults] setObject:@"gemini-2.5-flash" forKey:kGeminiModelPref];
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
// GỌI GOOGLE GEMINI REST API
// =========================================================================

static void CallGeminiTranslation(NSArray *texts,
                                  NSString *srcLang,
                                  NSString *tgtLang,
                                  NSUInteger attempt,
                                  NSUInteger maxTries,
                                  void (^completion)(NSArray *translatedTexts)) {
    
    NSString *currentKey = GetActiveGeminiKey();
    NSString *model = GetSavedGeminiModel();
    
    if ([currentKey length] == 0) {
        ShowGeminiSettingsPopup();
        completion(texts);
        return;
    }
    
    NSError *error;
    NSData *textsJsonData = [NSJSONSerialization dataWithJSONObject:texts options:0 error:&error];
    NSString *textsJsonString = [[NSString alloc] initWithData:textsJsonData encoding:NSUTF8StringEncoding];
    
    NSString *prompt = [NSString stringWithFormat:
        @"Bạn là dịch giả truyện tranh chuyên nghiệp.\n"
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
    
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    
    [[session dataTaskWithRequest:geminiReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *netError) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSInteger statusCode = httpResponse.statusCode;
        
        LOG(@"Gemini response status: %ld", (long)statusCode);
        
        // Nếu lỗi 404 (sai tên model) hoặc 429/400/403 (lỗi key) -> Tự động xoay key / thử model khác
        BOOL isKeyOrModelError = (statusCode == 429 || statusCode == 400 || statusCode == 401 || statusCode == 403 || statusCode == 404);
        
        if ((isKeyOrModelError || netError) && attempt < maxTries - 1) {
            LOG(@"Lỗi gọi Gemini (HTTP %ld). Đang xoay sang Key tiếp theo để thử lại...", (long)statusCode);
            RotateToNextKey();
            CallGeminiTranslation(texts, srcLang, tgtLang, attempt + 1, maxTries, completion);
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
            LOG(@"Không parse được bản dịch từ Gemini, trả về text gốc.");
            translatedList = texts;
        } else {
            LOG(@"Dịch thành công %lu câu bằng Gemini!", (unsigned long)[translatedList count]);
        }
        
        completion(translatedList);
    }] resume];
}

// =========================================================================
// METHOD SWIZZLING TRỰC TIẾP TRÊN NSURLSESSION (KHÔNG QUA PROTOCOL)
// =========================================================================

static void SwizzleMethod(Class cls, SEL origSel, SEL newSel) {
    Method origMethod = class_getInstanceMethod(cls, origSel);
    Method newMethod = class_getInstanceMethod(cls, newSel);
    if (origMethod && newMethod) {
        method_exchangeImplementations(origMethod, newMethod);
    }
}

@interface NSURLSession (EasyComixDirectHook)
@end

@implementation NSURLSession (EasyComixDirectHook)

- (NSURLSessionDataTask *)hook_dataTaskWithRequest:(NSURLRequest *)request
                                completionHandler:(void (^)(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error))completionHandler {
    
    NSString *urlString = request.URL.absoluteString;
    
    // 1. Chặn Endpoint Quota
    if ([urlString containsString:@"api.easycomix.app"] && [urlString containsString:@"/quota"]) {
        LOG(@"Directly Hooked Quota Request: %@", urlString);
        if (completionHandler) {
            NSDictionary *fakeQuota = @{
                @"success": @YES,
                @"data": @{
                    @"tier": @"free",
                    @"remaining": @999999,
                    @"resetAt": @"2099-01-01T00:00:00.000Z"
                }
            };
            NSData *data = [NSJSONSerialization dataWithJSONObject:fakeQuota options:0 error:nil];
            NSHTTPURLResponse *fakeResp = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                                      statusCode:200
                                                                     HTTPVersion:@"HTTP/1.1"
                                                                    headerFields:@{
                                                                        @"Content-Type": @"application/json; charset=utf-8",
                                                                        @"Access-Control-Allow-Origin": @"*"
                                                                    }];
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(data, fakeResp, nil);
            });
        }
        // Trả về task giả lập rỗng
        return [self hook_dataTaskWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"about:blank"]] completionHandler:nil];
    }
    
    // 2. Chặn Endpoint Dịch thuật
    if ([urlString containsString:@"api.easycomix.app"] && [urlString containsString:@"/translate"]) {
        LOG(@"Directly Hooked Translate Request: %@", urlString);
        
        NSData *bodyData = request.HTTPBody;
        if (bodyData && completionHandler) {
            NSDictionary *bodyJson = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
            NSArray *texts = bodyJson[@"texts"];
            NSString *srcLang = bodyJson[@"sourceLanguage"] ?: @"auto";
            NSString *tgtLang = bodyJson[@"targetLanguage"] ?: @"vi";
            
            if (texts && [texts count] > 0) {
                NSArray *keys = GetGeminiKeyPool();
                NSUInteger maxTries = [keys count] > 0 ? [keys count] : 1;
                
                CallGeminiTranslation(texts, srcLang, tgtLang, 0, maxTries, ^(NSArray *translatedTexts) {
                    NSDictionary *finalRespDict = @{
                        @"success": @YES,
                        @"data": @{
                            @"translations": translatedTexts
                        },
                        @"meta": @{
                            @"quota": @{
                                @"tier": @"free",
                                @"remaining": @999999,
                                @"resetAt": @"2099-01-01T00:00:00.000Z"
                            }
                        }
                    };
                    
                    NSData *resData = [NSJSONSerialization dataWithJSONObject:finalRespDict options:0 error:nil];
                    NSHTTPURLResponse *fakeResp = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                                              statusCode:200
                                                                             HTTPVersion:@"HTTP/1.1"
                                                                            headerFields:@{
                                                                                @"Content-Type": @"application/json; charset=utf-8",
                                                                                @"Access-Control-Allow-Origin": @"*"
                                                                            }];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completionHandler(resData, fakeResp, nil);
                    });
                });
                
                return [self hook_dataTaskWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"about:blank"]] completionHandler:nil];
            }
        }
    }
    
    // Cho các request khác (kể cả gọi sang Google Gemini) đi bình thường
    return [self hook_dataTaskWithRequest:request completionHandler:completionHandler];
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
    LOG(@"EasyComix Gemini Direct Hook Initialized!");
    
    SwizzleMethod([NSURLSession class],
                  @selector(dataTaskWithRequest:completionHandler:),
                  @selector(hook_dataTaskWithRequest:completionHandler:));
                  
    SwizzleMethod([UIViewController class],
                  @selector(viewDidAppear:),
                  @selector(hook_viewDidAppear:));
}
