#include "TestSupport.hpp"

#include <cstdio>
#include <exception>
#include <string>
#include <vector>

namespace test {

std::vector<Case>& registry() {
    static std::vector<Case> cases;
    return cases;
}

void fail(const char* file, int line, const std::string& message) {
    throw Failure(std::string(file) + ":" + std::to_string(line) + ": " + message);
}

std::string describe(bool value) { return value ? "true" : "false"; }

std::string describe(const std::string& value) { return "\"" + value + "\""; }

int runAll(int argc, char** argv) {
    const std::string filter = argc > 1 ? argv[1] : std::string();

    int passed = 0;
    int failed = 0;
    std::vector<std::string> failures;

    for (const Case& testCase : registry()) {
        const std::string fullName = testCase.suite + "." + testCase.name;
        if (!filter.empty() && fullName.find(filter) == std::string::npos) continue;

        try {
            testCase.function();
            ++passed;
        } catch (const Failure& failure) {
            ++failed;
            failures.push_back(std::string("✘ ") + fullName + "\n    " + failure.what());
        } catch (const std::exception& error) {
            ++failed;
            failures.push_back(std::string("✘ ") + fullName + "\n    unexpected exception: " +
                               error.what());
        } catch (...) {
            ++failed;
            failures.push_back(std::string("✘ ") + fullName + "\n    unknown exception");
        }
    }

    for (const std::string& failure : failures) {
        std::printf("%s\n", failure.c_str());
    }

    const int total = passed + failed;
    std::printf("\n%s  %d passed, %d failed (%d test%s)\n", failed == 0 ? "PASS" : "FAIL",
                passed, failed, total, total == 1 ? "" : "s");
    return failed;
}

}  // namespace test

int main(int argc, char** argv) { return test::runAll(argc, argv); }
