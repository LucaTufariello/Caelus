// FileSystem.hpp — the handful of file operations the app needs, without Foundation.

#pragma once

#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <vector>

namespace caelus::fsutil {

using path = std::filesystem::path;

// Whole-file read as text; nullopt when the file is missing or unreadable.
std::optional<std::string> readFile(const path& file);

// Create parent directories as needed. Returns false on failure.
bool createDirectories(const path& directory);

// Write via a sibling temporary file and rename, so a crash cannot leave a
// half-written document. Returns false and fills `error` on failure.
bool writeFileAtomic(const path& file, const std::string& text, std::string* error);

bool exists(const path& file);
bool removeAll(const path& file);
bool removeFile(const path& file);

// Every regular file under `root`, recursively; empty when `root` is missing.
std::vector<path> regularFiles(const path& root);

std::uintmax_t fileSize(const path& file);

// ~/Library/Application Support/<appName> when HOME is set, the temporary
// directory otherwise.
path applicationSupportDirectory(const std::string& appName);

path temporaryDirectory();

}  // namespace caelus::fsutil
