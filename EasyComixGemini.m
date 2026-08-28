#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

/**
 * EasyComix Gemini Tweak (Dylib) - Direct NSURLSession & URLProtocol Intercept
 * 1. Chuyển hướng toàn bộ dịch thuật sang Google Gemini API (hỗ trợ nhiều key & tự xoay vòng).
 * 2. Tự động fake Quota (999.999 lượt) & xóa cache hạn mức cũ.
 * 3. Chặn triệt để popup cập nhật (Soft Update & Force Update) để không bao giờ bị làm phiền hay khóa app.
 * 4. Tích hợp bộ đếm thống kê số lần và số câu thoại đã dịch.
 * 5. Standalone / Offline Fallback: Giả lập 100% API server EasyComix & Auth Supabase để app đăng nhập và hoạt động vĩnh viễn dù server sập.
 */

#define LOG(fmt, ...) NSLog(@"[EasyComixGemini] " fmt, ##__VA_ARGS__)

static NSString *const kGeminiKeysPref       = @"EasyComix_Gemini_Key_Pool";
static NSString *const kGeminiModelPref      = @"EasyComix_Gemini_Model_Name";
static NSString *const kGeminiTotalReqsPref  = @"EasyComix_Gemini_Total_Requests";
static NSString *const kGeminiTotalLinesPref = @"EasyComix_Gemini_Total_Lines";
static NSString *const kGemini25Model        = @"gemini-2.5-flash-lite";
static NSString *const kGemini35Model        = @"gemini-3.5-flash-lite";
static NSUInteger sCurrentKeyIndex = 0;

// =========================================================================
// BỘ ĐẾM THỐNG KÊ SỐ LẦN DỊCH
// =========================================================================

static NSInteger GetTotalTranslationRequests(void) {
    return [[NSUserDefaults standardUserDefaults] integerForKey:kGeminiTotalReqsPref];
}

static NSInteger GetTotalTranslatedLines(void) {
    return [[NSUserDefaults standardUserDefaults] integerForKey:kGeminiTotalLinesPref];
}

static void IncrementTranslationStats(NSUInteger lineCount) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSInteger totalReqs = [defaults integerForKey:kGeminiTotalReqsPref] + 1;
    NSInteger totalLines = [defaults integerForKey:kGeminiTotalLinesPref] + (NSInteger)lineCount;
    [defaults setInteger:totalReqs forKey:kGeminiTotalReqsPref];
    [defaults setInteger:totalLines forKey:kGeminiTotalLinesPref];
    [defaults synchronize];
}

static void ResetTranslationStats(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:kGeminiTotalReqsPref];
    [defaults removeObjectForKey:kGeminiTotalLinesPref];
    [defaults synchronize];
}

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
    if ([model isEqualToString:kGemini35Model]) return kGemini35Model;
    return kGemini25Model;
}

static void SaveGeminiSettings(NSString *rawKeys, NSString *model) {
    NSString *trimmedKeys = [rawKeys ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *safeModel = [model isEqualToString:kGemini35Model] ? kGemini35Model : kGemini25Model;
    [[NSUserDefaults standardUserDefaults] setObject:trimmedKeys forKey:kGeminiKeysPref];
    [[NSUserDefaults standardUserDefaults] setObject:safeModel forKey:kGeminiModelPref];
    [[NSUserDefaults standardUserDefaults] synchronize];
    sCurrentKeyIndex = 0;
    LOG(@"Đã cập nhật cấu hình: %lu keys, model: %@", (unsigned long)[GetGeminiKeyPool() count], safeModel);
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
        NSString *activeModel = GetSavedGeminiModel();
        NSInteger totalReqs = GetTotalTranslationRequests();
        NSInteger totalLines = GetTotalTranslatedLines();
        NSUInteger keyCount = [currentKeys count];
        NSUInteger activeKeyNum = keyCount > 0 ? ((sCurrentKeyIndex % keyCount) + 1) : 0;
        
        NSString *message = [NSString stringWithFormat:
            @"📊 Thống kê: Đã dịch %ld lần (%ld câu)\n"
            @"🔑 Key Pool: %lu key (Đang dùng Key #%lu)\n"
            @"⚡ Model hiện tại: %@\n\n"
            @"Dán danh sách API Key (phân cách bằng dấu phẩy hoặc xuống dòng):",
            (long)totalReqs, (long)totalLines,
            (unsigned long)keyCount, (unsigned long)activeKeyNum,
            activeModel];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🤖 Gemini Translator Settings"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
            textField.placeholder = @"AIza... , AIza...";
            textField.text = currentKeysText;
            textField.clearButtonMode = UITextFieldViewModeWhileEditing;
            textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
            textField.autocorrectionType = UITextAutocorrectionTypeNo;
        }];

        NSString *title25 = [activeModel isEqualToString:kGemini25Model]
            ? @"✓ Gemini 2.5 Flash Lite" : @"Gemini 2.5 Flash Lite";
        NSString *title35 = [activeModel isEqualToString:kGemini35Model]
            ? @"✓ Gemini 3.5 Flash Lite" : @"Gemini 3.5 Flash Lite";

        [alert addAction:[UIAlertAction actionWithTitle:title25
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            (void)action;
            SaveGeminiSettings(alert.textFields.firstObject.text, kGemini25Model);
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:title35
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            (void)action;
            SaveGeminiSettings(alert.textFields.firstObject.text, kGemini35Model);
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"🔄 Đặt lại thống kê dịch"
                                                 style:UIAlertActionStyleDestructive
                                               handler:^(UIAlertAction *action) {
            (void)action;
            ResetTranslationStats();
            SaveGeminiSettings(alert.textFields.firstObject.text, activeModel);
        }]];
        
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Đóng"
                                                               style:UIAlertActionStyleCancel
                                                             handler:nil];
        
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
        NSInteger statusCode = httpResponse.statusCode;
        
        LOG(@"Gemini (%@) response status: %ld", model, (long)statusCode);
        
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
                if ([parsed isKindOfClass:[NSArray class]] && [(NSArray *)parsed count] == [texts count]) {
                    translatedList = (NSArray *)parsed;
                }
            }
        }
        
        if (!translatedList || [translatedList count] == 0) {
            LOG(@"Không parse được bản dịch từ Gemini, trả về text gốc.");
            translatedList = texts;
        } else {
            IncrementTranslationStats([translatedList count]);
            LOG(@"Dịch thành công %lu câu bằng Gemini (%@)! (Tổng cộng: %ld lần, %ld câu)",
                (unsigned long)[translatedList count],
                model,
                (long)GetTotalTranslationRequests(),
                (long)GetTotalTranslatedLines());
        }
        
        completion(translatedList);
    }] resume];
}

// =========================================================================
// GIẢ LẬP PHẢN HỒI CHO AUTH SUPABASE & QUOTA
// =========================================================================

static NSDictionary *LocalQuotaResponse(void) {
    return @{
        @"success": @YES,
        @"data": @{
            @"tier": @"free",
            @"remaining": @999999,
            @"resetAt": @"2099-01-01T00:00:00.000Z"
        },
        @"meta": @{
            @"quota": @{
                @"tier": @"free",
                @"remaining": @999999,
                @"resetAt": @"2099-01-01T00:00:00.000Z"
            },
            @"liveQuota": @{
                @"tier": @"free",
                @"remaining": @999999,
                @"resetAt": @"2099-01-01T00:00:00.000Z"
            }
        }
    };
}

static NSDictionary *LocalSupabaseAuthResponse(void) {
    return @{
        @"access_token": @"gemini_local_token_eyJhY2Nlc3MiOiJ0cnVlIn0",
        @"token_type": @"bearer",
        @"expires_in": @(315360000),
        @"refresh_token": @"gemini_local_refresh_token",
        @"user": @{
            @"id": @"11111111-2222-3333-4444-555555555555",
            @"aud": @"authenticated",
            @"role": @"authenticated",
            @"email": @"vip@easycomix.gemini",
            @"email_confirmed_at": @"2024-01-01T00:00:00.000Z",
            @"confirmed_at": @"2024-01-01T00:00:00.000Z",
            @"last_sign_in_at": @"2024-01-01T00:00:00.000Z",
            @"app_metadata": @{ @"provider": @"google", @"providers": @[ @"google" ] },
            @"user_metadata": @{ @"full_name": @"Gemini VIP", @"name": @"Gemini VIP" },
            @"identities": @[],
            @"created_at": @"2024-01-01T00:00:00.000Z",
            @"updated_at": @"2024-01-01T00:00:00.000Z"
        }
    };
}

// =========================================================================
// NSURLPROTOCOL: BẮT TOÀN DIỆN MỌI REQUEST API ĐẾN EASYCOMIX & SUPABASE
// =========================================================================

static BOOL IsGeminiInterceptPath(NSURLRequest *request) {
    NSURL *url = request.URL;
    NSString *host = [url.host lowercaseString] ?: @"";
    if ([host containsString:@"easycomix.app"] || [host containsString:@"supabase.co"]) {
        return YES;
    }
    return NO;
}

@interface EasyComixGeminiURLProtocol : NSURLProtocol
@property (atomic, assign) BOOL ecStopped;
@end

@implementation EasyComixGeminiURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return IsGeminiInterceptPath(request);
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (NSData *)requestBodyData {
    NSData *body = self.request.HTTPBody;
    if (body.length > 0) return body;

    NSInputStream *stream = self.request.HTTPBodyStream;
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

- (void)finishWithJSONObject:(id)object {
    if (self.ecStopped) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                              statusCode:200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:@{
                                                                @"Content-Type": @"application/json; charset=utf-8",
                                                                @"Access-Control-Allow-Origin": @"*"
                                                            }];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)startLoading {
    NSString *urlString = self.request.URL.absoluteString ?: @"";
    NSString *path = self.request.URL.path ?: @"";
    LOG(@"NSURLProtocol intercepted: %@", urlString);

    // 1. Giả lập Auth Supabase nếu có request tới Supabase (giúp login thành công dù server sập)
    if ([urlString containsString:@"supabase.co"]) {
        if ([path containsString:@"/auth/v1/user"] || [path containsString:@"/auth/v1/token"]) {
            [self finishWithJSONObject:LocalSupabaseAuthResponse()];
            return;
        }
        [self finishWithJSONObject:@[]];
        return;
    }

    // 2. Quota config
    if ([path containsString:@"/quota/config"]) {
        [self finishWithJSONObject:@{
            @"success": @YES,
            @"data": @{
                @"tiers": @{
                    @"trial": @{ @"maxCalls": @999999 },
                    @"free": @{ @"maxCalls": @999999 },
                    @"pro": @{ @"maxCalls": @999999 }
                },
                @"live": @{
                    @"free": @{ @"maxCalls": @999999 },
                    @"pro": @{ @"maxCalls": @999999 }
                }
            }
        }];
        return;
    }

    // 3. Quota query
    if ([path containsString:@"/quota"]) {
        [self finishWithJSONObject:LocalQuotaResponse()];
        return;
    }

    // 4. Translate endpoint
    if ([path containsString:@"/translate"]) {
        NSData *bodyData = [self requestBodyData];
        NSDictionary *body = bodyData ? [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil] : nil;
        NSDictionary *payloadBody = [body[@"data"] isKindOfClass:[NSDictionary class]] ? body[@"data"] : body;
        NSArray *texts = [payloadBody[@"texts"] isKindOfClass:[NSArray class]] ? payloadBody[@"texts"] : nil;
        if (!texts && [payloadBody[@"text"] isKindOfClass:[NSString class]]) {
            texts = @[ payloadBody[@"text"] ];
        }
        NSString *source = [payloadBody[@"sourceLanguage"] isKindOfClass:[NSString class]] ? payloadBody[@"sourceLanguage"] : @"auto";
        NSString *target = [payloadBody[@"targetLanguage"] isKindOfClass:[NSString class]] ? payloadBody[@"targetLanguage"] : @"vi";

        if ([texts count] == 0) {
            LOG(@"Không đọc được texts. bodyLength=%lu keys=%@", (unsigned long)bodyData.length, body.allKeys);
            NSError *error = [NSError errorWithDomain:@"EasyComixGemini"
                                                 code:1001
                                             userInfo:@{NSLocalizedDescriptionKey: @"Request dịch không có texts"}];
            [self.client URLProtocol:self didFailWithError:error];
            return;
        }

        NSUInteger keyCount = [GetGeminiKeyPool() count];
        CallGeminiTranslation(texts, source, target, 0, MAX((NSUInteger)1, keyCount), ^(NSArray *translatedTexts) {
            [self finishWithJSONObject:@{
                @"success": @YES,
                @"data": @{ @"translations": translatedTexts },
                @"meta": LocalQuotaResponse()[@"meta"]
            }];
        });
        return;
    }

    // 5. Các endpoint khác của EasyComix server (Version check, Ad rules, Config, Auth, Profile...)
    [self finishWithJSONObject:@{
        @"success": @YES,
        @"data": @{
            @"version": @"99.9.9",
            @"latestVersion": @"1.0.18",
            @"minVersion": @"1.0.0",
            @"forceUpdate": @NO,
            @"isUpdateAvailable": @NO
        }
    }];
}

- (void)stopLoading {
    self.ecStopped = YES;
}

@end


static void PrependGeminiProtocol(NSURLSessionConfiguration *configuration) {
    if (!configuration) return;
    NSArray *existing = configuration.protocolClasses ?: @[];
    if ([existing containsObject:[EasyComixGeminiURLProtocol class]]) return;
    configuration.protocolClasses = [@[ [EasyComixGeminiURLProtocol class] ] arrayByAddingObjectsFromArray:existing];
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

// =========================================================================
// METHOD SWIZZLING TRỰC TIẾP TRÊN NSURLSESSION
// =========================================================================

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

@interface NSURLSession (EasyComixDirectHook)
@end

@implementation NSURLSession (EasyComixDirectHook)

- (NSURLSessionDataTask *)hook_dataTaskWithRequest:(NSURLRequest *)request
                                completionHandler:(void (^)(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error))completionHandler {
    
    NSString *urlString = request.URL.absoluteString;
    
    // 1. Chặn Auth Supabase (Giả lập session đăng nhập offline)
    if ([urlString containsString:@"supabase.co"]) {
        LOG(@"Directly Hooked Supabase Request: %@", urlString);
        if (completionHandler) {
            id respObj = [urlString containsString:@"/auth/v1/"] ? LocalSupabaseAuthResponse() : @[];
            NSData *data = [NSJSONSerialization dataWithJSONObject:respObj options:0 error:nil];
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
        return [self hook_dataTaskWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"about:blank"]] completionHandler:nil];
    }
    
    // 2. Chặn Endpoint Quota (GET/POST /api/v1/translate/quota)
    if ([urlString containsString:@"api.easycomix.app"] &&
        [urlString containsString:@"/quota"] &&
        ![urlString containsString:@"/quota/config"]) {
        
        LOG(@"Directly Hooked Quota Request: %@", urlString);
        if (completionHandler) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:LocalQuotaResponse() options:0 error:nil];
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
        return [self hook_dataTaskWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"about:blank"]] completionHandler:nil];
    }
    
    // 3. Chặn Endpoint Dịch thuật (/api/v1/translate và /translate/chapter)
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
                        @"meta": LocalQuotaResponse()[@"meta"]
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
    
    // 4. Chống sập server: Bất kỳ request nào khác đến api.easycomix.app đều trả về 200 OK giả lập
    if ([urlString containsString:@"api.easycomix.app"]) {
        LOG(@"Mocked EasyComix server request: %@", urlString);
        if (completionHandler) {
            NSDictionary *mockData = @{
                @"success": @YES,
                @"data": @{
                    @"version": @"99.9.9",
                    @"latestVersion": @"1.0.18",
                    @"minVersion": @"1.0.0",
                    @"forceUpdate": @NO,
                    @"isUpdateAvailable": @NO
                }
            };
            NSData *data = [NSJSONSerialization dataWithJSONObject:mockData options:0 error:nil];
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
        return [self hook_dataTaskWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"about:blank"]] completionHandler:nil];
    }
    
    return [self hook_dataTaskWithRequest:request completionHandler:completionHandler];
}

@end

// =========================================================================
// CHẶN TRIỆT ĐỂ BẢNG THÔNG BÁO CẬP NHẬT (SOFT UPDATE & FORCE UPDATE)
// =========================================================================

@interface NSBundle (EasyComixVersionHook)
@end

@implementation NSBundle (EasyComixVersionHook)

- (id)hook_objectForInfoDictionaryKey:(NSString *)key {
    // Trả về phiên bản 99.9.9 để AppVersionManager luôn thấy app ở bản mới nhất -> không bao giờ hiện popup update
    if ([key isEqualToString:@"CFBundleShortVersionString"]) {
        return @"99.9.9";
    }
    return [self hook_objectForInfoDictionaryKey:key];
}

@end

@interface UIViewController (EasyComixHook)
@end

@implementation UIViewController (EasyComixHook)

- (void)hook_viewDidAppear:(BOOL)animated {
    [self hook_viewDidAppear:animated];
    AddFloatingButtonToWindow();
}

- (void)hook_presentViewController:(UIViewController *)viewControllerToPresent
                          animated:(BOOL)flag
                        completion:(void (^)(void))completion {
    
    NSString *className = NSStringFromClass([viewControllerToPresent class]);
    // Chặn các Controller cập nhật nếu có
    if ([className containsString:@"Update"] ||
        [className containsString:@"SoftUpdate"] ||
        [className containsString:@"HardUpdate"]) {
        LOG(@"Đã tự động chặn hiển thị popup cập nhật: %@", className);
        if (completion) completion();
        return;
    }
    
    [self hook_presentViewController:viewControllerToPresent animated:flag completion:completion];
}

@end

// =========================================================================
// KHỞI TẠO TWEAK & TỰ ĐỘNG LÀM SẠCH HẠN MỨC CŨ
// =========================================================================

__attribute__((constructor))
static void InitEasyComixGeminiHook(void) {
    LOG(@"EasyComix Gemini Tweak Loaded. Model: %@, Đã dịch: %ld lần (%ld câu)",
        GetSavedGeminiModel(),
        (long)GetTotalTranslationRequests(),
        (long)GetTotalTranslatedLines());
    
    // Tự động xóa cache hạn mức cũ trong UserDefaults của app
    NSDictionary *defaultsDict = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    for (NSString *key in [defaultsDict allKeys]) {
        if ([key containsString:@"quota"] || [key containsString:@"Quota"] || [key containsString:@"limit"]) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
        }
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    // Hook version check của Bundle
    SwizzleMethod([NSBundle class],
                  @selector(objectForInfoDictionaryKey:),
                  @selector(hook_objectForInfoDictionaryKey:));
    
    // Hook NSURLSession
    SwizzleMethod([NSURLSession class],
                  @selector(dataTaskWithRequest:completionHandler:),
                  @selector(hook_dataTaskWithRequest:completionHandler:));

    // Hook URLProtocol & Configuration
    [NSURLProtocol registerClass:[EasyComixGeminiURLProtocol class]];
    SwizzleClassMethod([NSURLSessionConfiguration class],
                       @selector(defaultSessionConfiguration),
                       @selector(ec_defaultSessionConfiguration));
    SwizzleClassMethod([NSURLSessionConfiguration class],
                       @selector(ephemeralSessionConfiguration),
                       @selector(ec_ephemeralSessionConfiguration));
                  
    // Hook UIViewController (Thêm nút nổi & Chặn popup update)
    SwizzleMethod([UIViewController class],
                  @selector(viewDidAppear:),
                  @selector(hook_viewDidAppear:));
    SwizzleMethod([UIViewController class],
                  @selector(presentViewController:animated:completion:),
                  @selector(hook_presentViewController:animated:completion:));
}
