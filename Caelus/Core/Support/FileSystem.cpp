#include "FileSystem.hpp"

#include <atomic>
#include <cstdlib>
#include <fstream>
#include <system_error>
#include <unistd.h>

namespace caelus::fsutil {
namespace {

std::string uniqueSuffix() {
    static std::atomic<unsigned long> counter{0};
    return "." + std::to_string(static_cast<long>(::getpid())) + "." +
           std::to_string(counter.fetch_add(1));
}

}  // namespace

std::optional<std::string> readFile(const path& file) {
    std::ifstream stream(file, std::ios::binary);
    if (!stream) return std::nullopt;

    std::string text((std::istreambuf_iterator<char>(stream)),
                     std::istreambuf_iterator<char>());
    if (stream.bad()) return std::nullopt;
    return text;
}

bool createDirectories(const path& directory) {
    std::error_code error;
    std::filesystem::create_directories(directory, error);
    return !error;
}

bool writeFileAtomic(const path& file, const std::string& text, std::string* error) {
    const path temporary = file.string() + ".tmp" + uniqueSuffix();

    {
        std::ofstream stream(temporary, std::ios::binary | std::ios::trunc);
        if (!stream) {
            if (error) *error = "cannot open " + temporary.string();
            return false;
        }
        stream.write(text.data(), static_cast<std::streamsize>(text.size()));
        stream.flush();
        if (!stream) {
            if (error) *error = "cannot write " + temporary.string();
            std::error_code ignored;
            std::filesystem::remove(temporary, ignored);
            return false;
        }
    }

    std::error_code renameError;
    std::filesystem::rename(temporary, file, renameError);
    if (renameError) {
        if (error) *error = renameError.message();
        std::error_code ignored;
        std::filesystem::remove(temporary, ignored);
        return false;
    }
    return true;
}

bool exists(const path& file) {
    std::error_code error;
    return std::filesystem::exists(file, error);
}

bool removeAll(const path& file) {
    std::error_code error;
    std::filesystem::remove_all(file, error);
    return !error;
}

bool removeFile(const path& file) {
    std::error_code error;
    std::filesystem::remove(file, error);
    return !error;
}

std::vector<path> regularFiles(const path& root) {
    std::vector<path> files;
    std::error_code error;
    if (!std::filesystem::is_directory(root, error)) return files;

    std::filesystem::recursive_directory_iterator iterator(
        root, std::filesystem::directory_options::skip_permission_denied, error);
    const std::filesystem::recursive_directory_iterator end;
    while (!error && iterator != end) {
        std::error_code entryError;
        if (iterator->is_regular_file(entryError)) files.push_back(iterator->path());
        iterator.increment(error);
    }
    return files;
}

std::uintmax_t fileSize(const path& file) {
    std::error_code error;
    const std::uintmax_t size = std::filesystem::file_size(file, error);
    return error ? 0 : size;
}

path applicationSupportDirectory(const std::string& appName) {
    const char* home = std::getenv("HOME");
    if (home == nullptr || *home == '\0') return temporaryDirectory();
    return path(home) / "Library" / "Application Support" / appName;
}

path temporaryDirectory() {
    std::error_code error;
    const path directory = std::filesystem::temp_directory_path(error);
    if (error) return path("/tmp");
    return directory;
}

}  // namespace caelus::fsutil
