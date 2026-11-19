#include "URLSessionHttpClient.hpp"

#import <Foundation/Foundation.h>

namespace caelus {

struct URLSessionHttpClient::Impl {
    NSURLSession* session = nil;
};

URLSessionHttpClient::URLSessionHttpClient() : impl_(std::make_unique<Impl>()) {
    NSURLSessionConfiguration* configuration =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.HTTPAdditionalHeaders = @{@"Accept-Encoding" : @"gzip, deflate"};
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    impl_->session = [NSURLSession sessionWithConfiguration:configuration];
}

URLSessionHttpClient::~URLSessionHttpClient() {
    [impl_->session invalidateAndCancel];
}

HttpResponse URLSessionHttpClient::get(const std::string& url,
                                       const std::map<std::string, std::string>& headers,
                                       double timeoutSeconds) {
    NSString* urlString =
        [[NSString alloc] initWithBytes:url.data()
                                 length:url.size()
                               encoding:NSUTF8StringEncoding];
    NSURL* requestURL = [NSURL URLWithString:urlString];
    if (requestURL == nil) {
        throw HttpTransportError("invalid URL: " + url);
    }

    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:requestURL];
    request.timeoutInterval = timeoutSeconds;
    request.HTTPMethod = @"GET";
    for (const auto& [name, value] : headers) {
        NSString* nameString = [[NSString alloc] initWithUTF8String:name.c_str()];
        NSString* valueString = [[NSString alloc] initWithUTF8String:value.c_str()];
        [request setValue:valueString forHTTPHeaderField:nameString];
    }

    __block HttpResponse result;
    __block NSError* transportError = nil;
    __block NSData* body = nil;
    __block NSURLResponse* response = nil;

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSURLSessionDataTask* task =
        [impl_->session dataTaskWithRequest:request
                          completionHandler:^(NSData* data, NSURLResponse* taskResponse,
                                              NSError* error) {
                            body = data;
                            response = taskResponse;
                            transportError = error;
                            dispatch_semaphore_signal(semaphore);
                          }];
    [task resume];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    if (transportError != nil) {
        const char* message = transportError.localizedDescription.UTF8String;
        throw HttpTransportError(message != nullptr ? message : "network request failed");
    }

    if (![response isKindOfClass:[NSHTTPURLResponse class]]) {
        throw HttpTransportError("response was not HTTP");
    }

    NSHTTPURLResponse* http = (NSHTTPURLResponse*)response;
    result.status = static_cast<int>(http.statusCode);
    for (NSString* key in http.allHeaderFields) {
        NSString* value = http.allHeaderFields[key];
        std::string lowered(key.UTF8String ? key.UTF8String : "");
        for (char& c : lowered) {
            if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
        }
        result.headers[lowered] = value.UTF8String ? value.UTF8String : "";
    }
    if (body.length > 0) {
        result.body.assign(static_cast<const char*>(body.bytes), body.length);
    }
    return result;
}

}  // namespace caelus
