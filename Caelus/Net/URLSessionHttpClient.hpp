// URLSessionHttpClient.hpp — the macOS implementation of the core's HttpClient.

#pragma once

#include "../Core/Net/Http.hpp"

#include <memory>

namespace caelus {

// A synchronous GET over NSURLSession. The core calls this from background
// queues only, so blocking one queue is acceptable: catalog refreshes are
// strictly serial anyway.
class URLSessionHttpClient final : public HttpClient {
public:
    URLSessionHttpClient();
    ~URLSessionHttpClient() override;

    HttpResponse get(const std::string& url,
                     const std::map<std::string, std::string>& headers,
                     double timeoutSeconds) override;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace caelus
