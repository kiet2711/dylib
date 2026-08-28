#import <Foundation/Foundation.h>
#import <objc/runtime.h>

/**
 * EasyComix Gemini Tweak (Dylib)
 * Tự động chặn toàn bộ request dịch và quota của EasyComix và chuyển hướng sang Google Gemini API.
 */

// =========================================================================
// CẤU HÌNH API KEY VÀ MODEL CỦA BẠN TẠI ĐÂY
// =========================================================================
static NSString *const kDefaultGeminiAPIKey = @"YOUR_GEMINI_API_KEY";
static NSString *const kDefaultGeminiModel  = @"gemini-1.5-flash"; // gemini-1.5-flash hoặc gemini-2.0-flash

#define LOG(fmt, ...) NSLog(@"[EasyComixGemini] " fmt, ##__VA_ARGS__)

@interface EasyComixURLProtocol : NSURLProtocol <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSessionDataTask *task;
@end

@implementation EasyComixURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *urlString = request.URL.absoluteString;
    if (!urlString) return NO;
    
    // Tránh lặp vô tận khi chính dylib gọi sang Gemini
    if ([NSURLProtocol propertyForKey:@"EasyComixHandled" inRequest:request]) {
        return NO;
    }
    
    // Bắt toàn bộ domain api.easycomix.app liên quan đến translate hoặc quota
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
    
    // 1. Xử lý endpoint Quota / Credit -> Trả về vô hạn lượt ngay lập tức
    if ([urlString containsString:@"/quota"]) {
        NSDictionary *fakeQuota = @{
            @"success": @YES,
            @"data": @{
                @"tier": @"unlimited",
                @"remaining": @999999,
                @"resetAt": @"2099-01-01T00:00:00.000Z"
            }
        };
        [self sendJsonResponse:fakeQuota statusCode:200];
        return;
    }
    
    // 2. Xử lý endpoint Dịch thuật (/api/v1/translate hoặc /translate/chapter)
    if ([urlString containsString:@"/translate"]) {
        NSData *bodyData = self.request.HTTPBody;
        if (!bodyData && self.request.HTTPBodyStream) {
            // Đọc từ stream nếu body nằm trong stream
            bodyData = [self readDataFromStream:self.request.HTTPBodyStream];
        }
        
        if (!bodyData) {
            NSDictionary *emptyResp = @{@"success": @YES, @"data": @{@"translations": @[]}};
            [self sendJsonResponse:emptyResp statusCode:200];
            return;
        }
        
        NSError *jsonError = nil;
        NSDictionary *bodyJson = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:&jsonError];
        NSArray *texts = bodyJson[@"texts"];
        NSString *srcLang = bodyJson[@"sourceLanguage"] ?: @"auto";
        NSString *tgtLang = bodyJson[@"targetLanguage"] ?: @"vi";
        
        if (!texts || texts.count == 0) {
            NSDictionary *emptyResp = @{@"success": @YES, @"data": @{@"translations": @[]}};
            [self sendJsonResponse:emptyResp statusCode:200];
            return;
        }
        
        // Gọi Google Gemini API
        [self callGeminiWithTexts:texts sourceLang:srcLang targetLang:tgtLang];
    }
}

- (void)stopLoading {
    [self.task cancel];
}

#pragma mark - Helper xử lý Gemini API

- (void)callGeminiWithTexts:(NSArray *)texts sourceLang:(NSString *)srcLang targetLang:(NSString *)tgtLang {
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"EasyComix_Gemini_Key"] ?: kDefaultGeminiAPIKey;
    NSString *model = [[NSUserDefaults standardUserDefaults] stringForKey:@"EasyComix_Gemini_Model"] ?: kDefaultGeminiModel;
    
    NSError *error;
    NSData *textsJsonData = [NSJSONSerialization dataWithJSONObject:texts options:0 error:&error];
    NSString *textsJsonString = [[NSString alloc] initWithData:textsJsonData encoding:NSUTF8StringEncoding];
    
    NSString *prompt = [NSString stringWithFormat:
        @"Bạn là dịch giả truyện tranh (Manga/Manhwa/Comic) chuyên nghiệp.\n"
        @"Hãy dịch danh sách các câu thoại sau từ ngôn ngữ '%@' sang '%@'.\n"
        @"Quy tắc:\n"
        @"- Dịch mượt mà, tự nhiên, chuẩn phong cách thoại truyện tranh.\n"
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
                NSData *rawTextData = [rawText dataUsingEncoding:NSUTF8StringEncoding];
                translatedList = [NSJSONSerialization JSONObjectWithData:rawTextData options:0 error:nil];
            }
        }
        
        // Nếu lỗi Gemini thì giữ nguyên text gốc để không bị crash
        if (!translatedList || ![translatedList isKindOfClass:[NSArray class]]) {
            translatedList = texts;
        }
        
        // Đóng gói cấu trúc phản hồi hoàn chỉnh cho EasyComix
        NSDictionary *finalResponse = @{
            @"success": @YES,
            @"data": @{
                @"translations": translatedList
            },
            @"meta": @{
                @"quota": @{
                    @"tier": @"unlimited",
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
// SWIZZLING ĐỂ TẤT CẢ NSURLSESSION (KỂ CẢ SWIFT) ĐỀU PHẢI CHẠY QUA PROTOCOL
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

// Constructor được gọi ngay khi Dylib được load vào bộ nhớ của App
__attribute__((constructor))
static void InitEasyComixGeminiHook(void) {
    LOG(@"EasyComix Gemini Hook Loaded successfully!");
    
    // Đăng ký URLProtocol toàn cục
    [NSURLProtocol registerClass:[EasyComixURLProtocol class]];
    
    // Hook các cấu hình Session của NSURLSession / Swift URLSession
    SwizzleMethod([NSURLSessionConfiguration class],
                  @selector(defaultSessionConfiguration),
                  @selector(hook_defaultSessionConfiguration));
                  
    SwizzleMethod([NSURLSessionConfiguration class],
                  @selector(ephemeralSessionConfiguration),
                  @selector(hook_ephemeralSessionConfiguration));
}
