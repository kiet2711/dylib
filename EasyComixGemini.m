#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Security/Security.h>
#import <objc/runtime.h>

/**
 * EasyComix Gemini Tweak (Dylib) - Direct NSURLSession & URLProtocol Intercept
 * 1. TỰ ĐỘNG ĐĂNG NHẬP PRO VIP (Auto-Login): Cấp chuỗi JWT RFC 7519 & Session tương thích 100% Supabase Swift v2 (hỗ trợ cả camelCase & snake_case).
 * 2. Mở khóa TOÀN BỘ tính năng PRO (VIP trọn đời): Mở khóa Shortcut, Fonts tùy chỉnh, Không quảng cáo, Dịch AI không giới hạn.
 * 3. Hook RevenueCat Runtime & Intercept Network để giả lập thuê bao Pro trọn đời (2099).
 * 4. Chuyển hướng toàn bộ dịch thuật (Single Page, Batch Chapter, Live Scroll, Live Paged) sang Google Gemini API.
 * 5. Tự động fake Quota PRO (999.999 lượt) & xóa cache hạn mức cũ.
 * 6. Chặn triệt để popup cập nhật (Soft Update & Force Update) để không bao giờ bị làm phiền hay khóa app.
 * 7. Tích hợp bộ đếm thống kê số lần và số câu thoại đã dịch vào nút nổi 🤖 Key.
 * 8. Standalone / Offline Fallback: Giả lập 100% API server EasyComix & Auth Supabase để app hoạt động vĩnh viễn không phụ thuộc server gốc.
 */

#define LOG(fmt, ...) NSLog(@"[EasyComixGemini] " fmt, ##__VA_ARGS__)

static NSString *const kGeminiKeysPref       = @"EasyComix_Gemini_Key_Pool";
static NSString *const kGeminiModelPref      = @"EasyComix_Gemini_Model_Name";
static NSString *const kGeminiTotalReqsPref  = @"EasyComix_Gemini_Total_Requests";
static NSString *const kGeminiTotalLinesPref = @"EasyComix_Gemini_Total_Lines";
static NSString *const kGemini25Model        = @"gemini-2.5-flash-lite";
static NSString *const kGemini35Model        = @"gemini-3.5-flash-lite";
static NSUInteger sCurrentKeyIndex = 0;

// Chuỗi JWT RFC 7519 hợp lệ (Header: HS256, Payload: role=authenticated, exp=2100, is_pro=true)
static NSString *const kMockValidJWT = @"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMTExMTExMS0yMjIyLTMzMzMtNDQ0NC01NTU1NTU1NTU1NTUiLCJhdWQiOiJhdXRoZW50aWNhdGVkIiwicm9sZSI6ImF1dGhlbnRpY2F0ZWQiLCJlbWFpbCI6InByb192aXBAZWFzeWNvbWl4LmdlbWluaSIsImFwcF9tZXRhZGF0YSI6eyJwcm92aWRlciI6ImFwcGxlIiwicHJvdmlkZXJzIjpbImFwcGxlIiwiZ29vZ2xlIl19LCJ1c2VyX21ldGFkYXRhIjp7ImZ1bGxfbmFtZSI6IkdlbWluaSBQUk8gVklQIiwibmFtZSI6IkdlbWluaSBQUk8iLCJpc19wcm8iOnRydWUsInRpZXIiOiJwcm8ifSwiZXhwIjo0MTAyNDQ0ODAwLCJpYXQiOjE3MDAwMDAwMDB9.dummy_signature_for_local_mock_token_12345";
static NSString *const kMockRefreshToken = @"gemini_pro_valid_refresh_token_1234567890";

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
            @"👑 Trạng thái: PRO VIP (Dịch AI Gemini)\n"
            @"📊 Thống kê: Đã dịch %ld lần (%ld câu)\n"
            @"🔑 Key Pool: %lu key (Đang dùng Key #%lu)\n"
            @"⚡ Model: %@\n\n"
            @"Dán danh sách API Key (phân cách bằng dấu phẩy hoặc xuống dòng):",
            (long)totalReqs, (long)totalLines,
            (unsigned long)keyCount, (unsigned long)activeKeyNum,
            activeModel];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🤖 Gemini Pro Translator"
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
// HELPER TRÍCH XUẤT BODY DATA TỪ HTTPBODY HOẶC HTTPBODYSTREAM
// =========================================================================

static NSData *ExtractRequestBodyData(NSURLRequest *request) {
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

// =========================================================================
// GỌI GOOGLE GEMINI REST API
// =========================================================================

static void CallGeminiTranslation(NSArray<NSString *> *texts,
                                  NSString *srcLang,
                                  NSString *tgtLang,
                                  NSUInteger attempt,
                                  NSUInteger maxTries,
                                  void (^completion)(NSArray<NSString *> *translatedTexts)) {
    
    if ([texts count] == 0) {
        completion(@[]);
        return;
    }

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
        @"Bạn là dịch giả truyện tranh (manga/manhwa/comic) chuyên nghiệp.\n"
        @"Hãy dịch danh sách các câu thoại sau từ ngôn ngữ '%@' sang '%@'.\n"
        @"Quy tắc:\n"
        @"- Dịch mượt mà, cảm xúc tự nhiên, đúng ngữ cảnh thoại truyện tranh.\n"
        @"- Trả về DUY NHẤT một JSON Array mảng chuỗi theo đúng thứ tự (ví dụ: [\"câu 1\", \"câu 2\"]).\n"
        @"- KHÔNG thêm bất kỳ markdown, lời giải thích hay ký tự nào ngoài JSON Array.\n\n"
        @"Danh sách câu cần dịch:\n%@", srcLang, tgtLang, textsJsonString];
    
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
        
        BOOL isKeyOrModelError = (statusCode == 429 || statusCode == 400 || statusCode == 401 || statusCode == 403 || statusCode == 404 || statusCode >= 500);
        
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
// GIẢ LẬP PHẢN HỒI PRO: REVENUECAT, SUPABASE & EASYCOMIX QUOTA
// =========================================================================

static NSDictionary *LocalQuotaResponse(void) {
    return @{
        @"success": @YES,
        @"data": @{
            @"tier": @"pro",
            @"remaining": @999999,
            @"resetAt": @"2099-01-01T00:00:00.000Z"
        },
        @"meta": @{
            @"quota": @{
                @"tier": @"pro",
                @"remaining": @999999,
                @"resetAt": @"2099-01-01T00:00:00.000Z"
            },
            @"liveQuota": @{
                @"tier": @"pro",
                @"remaining": @999999,
                @"resetAt": @"2099-01-01T00:00:00.000Z"
            }
        }
    };
}

static NSDictionary *LocalQuotaConfigResponse(void) {
    return @{
        @"success": @YES,
        @"data": @{
            @"tiers": @{
                @"trial": @{ @"maxCalls": @999999 },
                @"free": @{ @"maxCalls": @999999 },
                @"pro": @{ @"maxCalls": @999999 }
            },
            @"live": @{
                @"trial": @{ @"maxCalls": @999999 },
                @"free": @{ @"maxCalls": @999999 },
                @"pro": @{ @"maxCalls": @999999 }
            },
            @"emails": @[]
        },
        @"meta": LocalQuotaResponse()[@"meta"]
    };
}

static NSDictionary *LocalAdRulesResponse(void) {
    return @{
        @"success": @YES,
        @"data": @{
            @"version": @"1.0.0",
            @"rules": @[]
        }
    };
}

static NSDictionary *LocalGenericSuccessResponse(void) {
    return @{
        @"success": @YES,
        @"data": @{
            @"version": @"99.9.9",
            @"latestVersion": @"1.0.18",
            @"minVersion": @"1.0.0",
            @"forceUpdate": @NO,
            @"isUpdateAvailable": @NO,
            @"is_pro": @YES,
            @"tier": @"pro",
            @"emails": @[]
        }
    };
}

static NSDictionary *LocalRevenueCatSubscriberResponse(void) {
    return @{
        @"request_date": @"2026-08-28T10:00:00Z",
        @"request_date_ms": @(1787911200000),
        @"subscriber": @{
            @"entitlements": @{
                @"pro": @{
                    @"expires_date": @"2099-12-31T23:59:59Z",
                    @"grace_period_expires_date": [NSNull null],
                    @"product_identifier": @"easycomix_pro_yearly",
                    @"purchase_date": @"2024-01-01T00:00:00Z"
                },
                @"premium": @{
                    @"expires_date": @"2099-12-31T23:59:59Z",
                    @"grace_period_expires_date": [NSNull null],
                    @"product_identifier": @"easycomix_pro_yearly",
                    @"purchase_date": @"2024-01-01T00:00:00Z"
                },
                @"shortcuts": @{
                    @"expires_date": @"2099-12-31T23:59:59Z",
                    @"grace_period_expires_date": [NSNull null],
                    @"product_identifier": @"easycomix_pro_yearly",
                    @"purchase_date": @"2024-01-01T00:00:00Z"
                },
                @"all_access": @{
                    @"expires_date": @"2099-12-31T23:59:59Z",
                    @"grace_period_expires_date": [NSNull null],
                    @"product_identifier": @"easycomix_pro_yearly",
                    @"purchase_date": @"2024-01-01T00:00:00Z"
                }
            },
            @"first_seen": @"2024-01-01T00:00:00Z",
            @"last_seen": @"2026-08-28T10:00:00Z",
            @"management_url": @"https://apps.apple.com/account/subscriptions",
            @"non_subscriptions": @{},
            @"original_app_user_id": @"gemini_pro_vip_user",
            @"original_application_version": @"1.0.0",
            @"original_purchase_date": @"2024-01-01T00:00:00Z",
            @"other_purchases": @{},
            @"subscriptions": @{
                @"easycomix_pro_yearly": @{
                    @"auto_resume_date": [NSNull null],
                    @"billing_issues_detected_at": [NSNull null],
                    @"expires_date": @"2099-12-31T23:59:59Z",
                    @"grace_period_expires_date": [NSNull null],
                    @"is_sandbox": @NO,
                    @"original_purchase_date": @"2024-01-01T00:00:00Z",
                    @"ownership_type": @"PURCHASED",
                    @"period_type": @"normal",
                    @"purchase_date": @"2024-01-01T00:00:00Z",
                    @"refunded_at": [NSNull null],
                    @"store": @"app_store",
                    @"store_transaction_id": @"1000000000000001",
                    @"unsubscribe_detected_at": [NSNull null]
                }
            }
        }
    };
}

/**
 * Cung cấp Session Supabase tương thích 100% cả camelCase (Swift JSONDecoder) và snake_case (GoTrue API)
 */
static NSData *GetMockSupabaseSessionData(void) {
    NSDictionary *sessionDict = @{
        @"accessToken": kMockValidJWT,
        @"access_token": kMockValidJWT,
        @"tokenType": @"bearer",
        @"token_type": @"bearer",
        @"expiresIn": @(315360000),
        @"expires_in": @(315360000),
        @"expiresAt": @(4102444800),
        @"expires_at": @(4102444800),
        @"refreshToken": kMockRefreshToken,
        @"refresh_token": kMockRefreshToken,
        @"user": @{
            @"id": @"11111111-2222-3333-4444-555555555555",
            @"aud": @"authenticated",
            @"role": @"authenticated",
            @"email": @"pro_vip@easycomix.gemini",
            @"phone": @"",
            @"emailConfirmedAt": @"2024-01-01T00:00:00Z",
            @"email_confirmed_at": @"2024-01-01T00:00:00Z",
            @"confirmedAt": @"2024-01-01T00:00:00Z",
            @"confirmed_at": @"2024-01-01T00:00:00Z",
            @"lastSignInAt": @"2024-01-01T00:00:00Z",
            @"last_sign_in_at": @"2024-01-01T00:00:00Z",
            @"createdAt": @"2024-01-01T00:00:00Z",
            @"created_at": @"2024-01-01T00:00:00Z",
            @"updatedAt": @"2024-01-01T00:00:00Z",
            @"updated_at": @"2024-01-01T00:00:00Z",
            @"appMetadata": @{ @"provider": @"apple", @"providers": @[ @"apple", @"google" ] },
            @"app_metadata": @{ @"provider": @"apple", @"providers": @[ @"apple", @"google" ] },
            @"userMetadata": @{
                @"full_name": @"Gemini PRO VIP",
                @"name": @"Gemini PRO",
                @"is_pro": @YES,
                @"tier": @"pro"
            },
            @"user_metadata": @{
                @"full_name": @"Gemini PRO VIP",
                @"name": @"Gemini PRO",
                @"is_pro": @YES,
                @"tier": @"pro"
            },
            @"identities": @[]
        }
    };
    return [NSJSONSerialization dataWithJSONObject:sessionDict options:0 error:nil];
}

static NSDictionary *LocalSupabaseAuthResponse(void) {
    return [NSJSONSerialization JSONObjectWithData:GetMockSupabaseSessionData() options:0 error:nil];
}

// =========================================================================
// XỬ LÝ REQUEST DỊCH THUẬT (SINGLE PAGE, CHAPTER BATCH, LIVE SCROLL, LIVE PAGED)
// =========================================================================

static void HandleTranslationRequest(NSURLRequest *request,
                                     void (^completion)(NSData *responseData, NSHTTPURLResponse *response, NSError *error)) {
    NSData *bodyData = ExtractRequestBodyData(request);
    if (!bodyData) {
        LOG(@"Không đọc được bodyData của translate request: %@", request.URL.absoluteString);
        if (completion) {
            NSDictionary *emptyResp = @{
                @"success": @YES,
                @"data": @{ @"translations": @[] },
                @"meta": LocalQuotaResponse()[@"meta"]
            };
            NSData *resData = [NSJSONSerialization dataWithJSONObject:emptyResp options:0 error:nil];
            NSHTTPURLResponse *fakeResp = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                                      statusCode:200
                                                                     HTTPVersion:@"HTTP/1.1"
                                                                    headerFields:@{
                                                                        @"Content-Type": @"application/json; charset=utf-8",
                                                                        @"Access-Control-Allow-Origin": @"*"
                                                                    }];
            completion(resData, fakeResp, nil);
        }
        return;
    }

    NSDictionary *bodyJson = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
    NSDictionary *payloadBody = [bodyJson[@"data"] isKindOfClass:[NSDictionary class]] ? bodyJson[@"data"] : bodyJson;

    // 1. Trường hợp Chapter / Live translation (bubbles: [ { id: ..., text: ... } ])
    NSArray *bubbles = [payloadBody[@"bubbles"] isKindOfClass:[NSArray class]] ? payloadBody[@"bubbles"] : nil;
    if (bubbles && [bubbles count] > 0) {
        LOG(@"Intercepted Chapter/Live Translation with %lu bubbles", (unsigned long)[bubbles count]);
        NSMutableArray<NSString *> *texts = [NSMutableArray arrayWithCapacity:[bubbles count]];
        NSMutableArray<NSString *> *bubbleIds = [NSMutableArray arrayWithCapacity:[bubbles count]];
        
        for (id b in bubbles) {
            if ([b isKindOfClass:[NSDictionary class]]) {
                NSString *txt = [b[@"text"] isKindOfClass:[NSString class]] ? b[@"text"] : @"";
                NSString *bId = [b[@"id"] isKindOfClass:[NSString class]] ? b[@"id"] : [NSString stringWithFormat:@"%@", b[@"id"] ?: @""];
                [texts addObject:txt];
                [bubbleIds addObject:bId];
            } else if ([b isKindOfClass:[NSString class]]) {
                [texts addObject:b];
                [bubbleIds addObject:@""];
            }
        }

        NSString *srcLang = [payloadBody[@"sourceLang"] isKindOfClass:[NSString class]] ? payloadBody[@"sourceLang"] : ([payloadBody[@"sourceLanguage"] isKindOfClass:[NSString class]] ? payloadBody[@"sourceLanguage"] : @"auto");
        NSString *tgtLang = [payloadBody[@"targetLang"] isKindOfClass:[NSString class]] ? payloadBody[@"targetLang"] : ([payloadBody[@"targetLanguage"] isKindOfClass:[NSString class]] ? payloadBody[@"targetLanguage"] : @"vi");

        NSArray *keys = GetGeminiKeyPool();
        NSUInteger maxTries = [keys count] > 0 ? [keys count] : 1;

        CallGeminiTranslation(texts, srcLang, tgtLang, 0, maxTries, ^(NSArray *translatedTexts) {
            NSMutableArray *translatedItems = [NSMutableArray arrayWithCapacity:[bubbles count]];
            for (NSUInteger i = 0; i < [bubbles count]; i++) {
                NSString *bId = (i < [bubbleIds count]) ? bubbleIds[i] : @"";
                NSString *transTxt = (i < [translatedTexts count]) ? translatedTexts[i] : (i < [texts count] ? texts[i] : @"");
                [translatedItems addObject:@{
                    @"id": bId,
                    @"text": transTxt
                }];
            }

            NSDictionary *finalResp = @{
                @"success": @YES,
                @"data": @{
                    @"translations": translatedItems
                },
                @"meta": LocalQuotaResponse()[@"meta"]
            };

            NSData *resData = [NSJSONSerialization dataWithJSONObject:finalResp options:0 error:nil];
            NSHTTPURLResponse *fakeResp = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                                      statusCode:200
                                                                     HTTPVersion:@"HTTP/1.1"
                                                                    headerFields:@{
                                                                        @"Content-Type": @"application/json; charset=utf-8",
                                                                        @"Access-Control-Allow-Origin": @"*"
                                                                    }];
            if (completion) completion(resData, fakeResp, nil);
        });
        return;
    }

    // 2. Trường hợp Single translate (texts: [ "câu 1", "câu 2" ] hoặc text: "câu 1")
    NSArray *texts = [payloadBody[@"texts"] isKindOfClass:[NSArray class]] ? payloadBody[@"texts"] : nil;
    if (!texts && [payloadBody[@"text"] isKindOfClass:[NSString class]]) {
        texts = @[ payloadBody[@"text"] ];
    }

    if (texts && [texts count] > 0) {
        LOG(@"Intercepted Single Translation with %lu texts", (unsigned long)[texts count]);
        NSString *srcLang = [payloadBody[@"sourceLanguage"] isKindOfClass:[NSString class]] ? payloadBody[@"sourceLanguage"] : ([payloadBody[@"sourceLang"] isKindOfClass:[NSString class]] ? payloadBody[@"sourceLang"] : @"auto");
        NSString *tgtLang = [payloadBody[@"targetLanguage"] isKindOfClass:[NSString class]] ? payloadBody[@"targetLanguage"] : ([payloadBody[@"targetLang"] isKindOfClass:[NSString class]] ? payloadBody[@"targetLang"] : @"vi");

        NSArray *keys = GetGeminiKeyPool();
        NSUInteger maxTries = [keys count] > 0 ? [keys count] : 1;

        CallGeminiTranslation(texts, srcLang, tgtLang, 0, maxTries, ^(NSArray *translatedTexts) {
            NSDictionary *finalResp = @{
                @"success": @YES,
                @"data": @{
                    @"translations": translatedTexts ?: texts
                },
                @"meta": LocalQuotaResponse()[@"meta"]
            };

            NSData *resData = [NSJSONSerialization dataWithJSONObject:finalResp options:0 error:nil];
            NSHTTPURLResponse *fakeResp = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                                      statusCode:200
                                                                     HTTPVersion:@"HTTP/1.1"
                                                                    headerFields:@{
                                                                        @"Content-Type": @"application/json; charset=utf-8",
                                                                        @"Access-Control-Allow-Origin": @"*"
                                                                    }];
            if (completion) completion(resData, fakeResp, nil);
        });
        return;
    }

    // Fallback nếu rỗng
    LOG(@"Request /translate không có texts hay bubbles hợp lệ. Trả về rỗng.");
    NSDictionary *emptyResp = @{
        @"success": @YES,
        @"data": @{
            @"translations": @[]
        },
        @"meta": LocalQuotaResponse()[@"meta"]
    };
    NSData *resData = [NSJSONSerialization dataWithJSONObject:emptyResp options:0 error:nil];
    NSHTTPURLResponse *fakeResp = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                              statusCode:200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:@{
                                                                @"Content-Type": @"application/json; charset=utf-8",
                                                                @"Access-Control-Allow-Origin": @"*"
                                                            }];
    if (completion) completion(resData, fakeResp, nil);
}

// =========================================================================
// DYLD INTERPOSING CHO KEYCHAIN (TỰ ĐỘNG CẤP SESSION PRO CHO SUPABASE AUTH)
// =========================================================================

typedef struct interpose_s {
    const void *new_func;
    const void *orig_func;
} interpose_t;

#define DYLD_INTERPOSE(_replacement, _replacee) \
__attribute__((used)) static const interpose_t _interpose_##_replacee \
__attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

static OSStatus my_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *queryDict = (__bridge NSDictionary *)query;
    id account = queryDict[(__bridge id)kSecAttrAccount];
    id service = queryDict[(__bridge id)kSecAttrService];
    NSString *combined = [NSString stringWithFormat:@"%@ %@", account ?: @"", service ?: @""];
    
    if ([combined containsString:@"supabase"] ||
        [combined containsString:@"auth"] ||
        [combined containsString:@"session"] ||
        [combined containsString:@"token"]) {
        
        if (result) {
            NSData *sessionData = GetMockSupabaseSessionData();
            if ([queryDict[(__bridge id)kSecReturnData] boolValue]) {
                *result = (CFTypeRef)CFBridgingRetain(sessionData);
                LOG(@"SecItemCopyMatching (data) intercepted for %@", combined);
                return errSecSuccess;
            } else if ([queryDict[(__bridge id)kSecReturnAttributes] boolValue]) {
                NSDictionary *attrDict = @{
                    (__bridge id)kSecAttrAccount: account ?: @"supabase.auth.token",
                    (__bridge id)kSecAttrService: service ?: @"supabase.auth.token",
                    (__bridge id)kSecValueData: sessionData
                };
                *result = (CFTypeRef)CFBridgingRetain(attrDict);
                LOG(@"SecItemCopyMatching (attributes) intercepted for %@", combined);
                return errSecSuccess;
            }
        }
    }
    
    return SecItemCopyMatching(query, result);
}
DYLD_INTERPOSE(my_SecItemCopyMatching, SecItemCopyMatching);

// =========================================================================
// TỰ ĐỘNG GHI SESSION PRO VÀO KEYCHAIN & USERDEFAULTS
// =========================================================================

static void AutoSeedSupabaseProSession(void) {
    NSData *sessionData = GetMockSupabaseSessionData();
    NSString *sessionString = [[NSString alloc] initWithData:sessionData encoding:NSUTF8StringEncoding];
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:sessionData forKey:@"supabase.session"];
    [defaults setObject:sessionData forKey:@"supabase.auth.token"];
    [defaults setObject:sessionString forKey:@"supabase.session.string"];
    [defaults setObject:sessionString forKey:@"supabase.gotrue.swift"];
    [defaults setObject:@"pro" forKey:@"translationMode"];
    [defaults setObject:@YES forKey:@"is_pro"];
    [defaults setObject:@YES forKey:@"isPro"];
    [defaults setObject:@YES forKey:@"hasProSubscription"];
    [defaults setObject:@"pro" forKey:@"tier"];
    [defaults synchronize];
    
    NSArray *keys = @[
        @"supabase.auth.token",
        @"supabase.session",
        @"supabase.gotrue.swift",
        @"app.easycomix.session",
        @"supabase.auth.refreshToken",
        @"supabase.auth.accessToken"
    ];
    for (NSString *key in keys) {
        NSDictionary *delQuery = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount: key
        };
        SecItemDelete((__bridge CFDictionaryRef)delQuery);
        
        NSDictionary *addQuery = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount: key,
            (__bridge id)kSecAttrService: key,
            (__bridge id)kSecValueData: sessionData,
            (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock
        };
        SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);
    }
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"AuthClient.didChangeAuthStateNotification" object:nil];
        LOG(@"Đã phát thông báo AuthClient.didChangeAuthStateNotification!");
    });

    LOG(@"Đã tự động nạp phiên đăng nhập PRO VIP (JWT RFC 7519 + Dual Camel/Snake Case) vào Keychain & UserDefaults!");
}

// =========================================================================
// NSURLPROTOCOL: BẮT TOÀN DIỆN MỌI REQUEST API ĐẾN EASYCOMIX, SUPABASE & REVENUECAT
// =========================================================================

static BOOL IsGeminiInterceptPath(NSURLRequest *request) {
    NSURL *url = request.URL;
    NSString *host = [url.host lowercaseString] ?: @"";
    if ([host containsString:@"easycomix.app"] ||
        [host containsString:@"supabase.co"] ||
        [host containsString:@"revenuecat.com"]) {
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

- (void)finishWithData:(NSData *)data response:(NSHTTPURLResponse *)response {
    if (self.ecStopped) return;
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)startLoading {
    NSString *urlString = self.request.URL.absoluteString ?: @"";
    NSString *path = self.request.URL.path ?: @"";
    LOG(@"NSURLProtocol intercepted: %@", urlString);

    // 1. Giả lập Thuê bao PRO RevenueCat (Mở khóa Shortcut, Unlimited, Fonts...)
    if ([urlString containsString:@"revenuecat.com"]) {
        [self finishWithJSONObject:LocalRevenueCatSubscriberResponse()];
        return;
    }

    // 2. Giả lập Auth Supabase (Tự động đăng nhập thành công)
    if ([urlString containsString:@"supabase.co"]) {
        if ([path containsString:@"/auth/v1/user"] ||
            [path containsString:@"/auth/v1/token"] ||
            [path containsString:@"/auth/v1/signup"] ||
            [path containsString:@"/auth/v1/recover"] ||
            [path containsString:@"/auth/v1/authorize"] ||
            [path containsString:@"/auth/v1/logout"]) {
            [self finishWithJSONObject:LocalSupabaseAuthResponse()];
            return;
        }
        [self finishWithJSONObject:@[]];
        return;
    }

    // 3. Quota config (PRO tier)
    if ([path containsString:@"/quota/config"]) {
        [self finishWithJSONObject:LocalQuotaConfigResponse()];
        return;
    }

    // 4. Quota query (PRO tier)
    if ([path containsString:@"/quota"]) {
        [self finishWithJSONObject:LocalQuotaResponse()];
        return;
    }

    // 5. Translate endpoints (/api/v1/translate và /api/v1/translate/chapter)
    if ([path containsString:@"/translate"]) {
        HandleTranslationRequest(self.request, ^(NSData *responseData, NSHTTPURLResponse *response, NSError *error) {
            if (responseData && response) {
                [self finishWithData:responseData response:response];
            } else {
                [self finishWithJSONObject:@{
                    @"success": @YES,
                    @"data": @{ @"translations": @[] },
                    @"meta": LocalQuotaResponse()[@"meta"]
                }];
            }
        });
        return;
    }

    // 6. Ad rules & Config
    if ([path containsString:@"/ad-rules"]) {
        [self finishWithJSONObject:LocalAdRulesResponse()];
        return;
    }

    // 7. Các endpoint khác của EasyComix server (Version check, Config, Whitelist, Feedback, Profile...)
    [self finishWithJSONObject:LocalGenericSuccessResponse()];
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
    
    NSString *urlString = request.URL.absoluteString ?: @"";
    NSString *path = request.URL.path ?: @"";
    
    // 1. Chặn RevenueCat (Mở khóa PRO trọn đời)
    if ([urlString containsString:@"revenuecat.com"]) {
        LOG(@"Directly Hooked RevenueCat Pro Request: %@", urlString);
        if (completionHandler) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:LocalRevenueCatSubscriberResponse() options:0 error:nil];
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

    // 2. Chặn Auth Supabase (Giả lập session đăng nhập offline)
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
    
    // 3. Chặn Quota Config (/quota/config)
    if ([urlString containsString:@"api.easycomix.app"] && [path containsString:@"/quota/config"]) {
        LOG(@"Directly Hooked Quota Config Request: %@", urlString);
        if (completionHandler) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:LocalQuotaConfigResponse() options:0 error:nil];
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

    // 4. Chặn Endpoint Quota (/quota)
    if ([urlString containsString:@"api.easycomix.app"] && [path containsString:@"/quota"]) {
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
    
    // 5. Chặn Endpoint Dịch thuật (/api/v1/translate và /api/v1/translate/chapter)
    if ([urlString containsString:@"api.easycomix.app"] && [path containsString:@"/translate"]) {
        LOG(@"Directly Hooked Translate Request: %@", urlString);
        if (completionHandler) {
            HandleTranslationRequest(request, ^(NSData *responseData, NSHTTPURLResponse *response, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler(responseData, response, error);
                });
            });
        }
        return [self hook_dataTaskWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"about:blank"]] completionHandler:nil];
    }
    
    // 6. Chặn Ad rules (/config/ad-rules)
    if ([urlString containsString:@"api.easycomix.app"] && [path containsString:@"/ad-rules"]) {
        LOG(@"Directly Hooked AdRules Request: %@", urlString);
        if (completionHandler) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:LocalAdRulesResponse() options:0 error:nil];
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

    // 7. Chống sập server: Bất kỳ request nào khác đến api.easycomix.app đều trả về 200 OK giả lập
    if ([urlString containsString:@"api.easycomix.app"]) {
        LOG(@"Mocked EasyComix server request: %@", urlString);
        if (completionHandler) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:LocalGenericSuccessResponse() options:0 error:nil];
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
// RUNTIME SWIZZLING CHO REVENUECAT (MỞ KHÓA PRO TRỌN ĐỜI CHO APPS & SHORTCUTS)
// =========================================================================

@interface NSObject (RevenueCatProHook)
- (BOOL)rc_hook_isActive;
- (BOOL)rc_hook_willRenew;
- (NSDate *)rc_hook_expirationDate;
- (NSSet *)rc_hook_activeSubscriptions;
- (NSSet *)rc_hook_allPurchasedProductIdentifiers;
@end

@implementation NSObject (RevenueCatProHook)

- (BOOL)rc_hook_isActive {
    return YES;
}

- (BOOL)rc_hook_willRenew {
    return YES;
}

- (NSDate *)rc_hook_expirationDate {
    return [NSDate dateWithTimeIntervalSince1970:4102444800]; // Năm 2100
}

- (NSSet *)rc_hook_activeSubscriptions {
    return [NSSet setWithObjects:@"easycomix_pro_yearly", @"easycomix_pro_monthly", nil];
}

- (NSSet *)rc_hook_allPurchasedProductIdentifiers {
    return [NSSet setWithObjects:@"easycomix_pro_yearly", @"easycomix_pro_monthly", nil];
}

@end

// =========================================================================
// CHẶN BẢNG THÔNG BÁO CẬP NHẬT
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
    
    // 1. Chặn các Controller cập nhật nếu có
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
// KHỞI TẠO TWEAK & TỰ ĐỘNG MỞ KHÓA PRO + NẠP SESSION AUTH
// =========================================================================

__attribute__((constructor))
static void InitEasyComixGeminiHook(void) {
    LOG(@"EasyComix Gemini PRO Tweak Loaded. Model: %@, Đã dịch: %ld lần (%ld câu)",
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
    
    // Tự động nạp session Pro VIP vào Keychain & UserDefaults
    AutoSeedSupabaseProSession();
    
    // Mở khóa PRO Runtime trên RevenueCat SDK
    Class rcEntitlementInfo = NSClassFromString(@"RCEntitlementInfo");
    if (rcEntitlementInfo) {
        SwizzleMethod(rcEntitlementInfo, @selector(isActive), @selector(rc_hook_isActive));
        SwizzleMethod(rcEntitlementInfo, @selector(willRenew), @selector(rc_hook_willRenew));
        SwizzleMethod(rcEntitlementInfo, @selector(expirationDate), @selector(rc_hook_expirationDate));
        LOG(@"RevenueCat RCEntitlementInfo PRO hook activated!");
    }
    
    Class rcCustomerInfo = NSClassFromString(@"RCCustomerInfo");
    if (rcCustomerInfo) {
        SwizzleMethod(rcCustomerInfo, @selector(activeSubscriptions), @selector(rc_hook_activeSubscriptions));
        SwizzleMethod(rcCustomerInfo, @selector(allPurchasedProductIdentifiers), @selector(rc_hook_allPurchasedProductIdentifiers));
        LOG(@"RevenueCat RCCustomerInfo PRO hook activated!");
    }
    
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
