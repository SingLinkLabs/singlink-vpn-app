// Copyright 2026 SingLinkLabs
// SPDX-License-Identifier: Apache-2.0
#include "credential_store.h"
#include <windows.h>
#include <dpapi.h>
#include <objbase.h>
#include <shlobj.h>
#include <flutter/standard_method_codec.h>
#include <filesystem>
#include <memory>
#include <optional>
#include <regex>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
const std::regex kReference("^slk_v1_[A-Za-z0-9_-]{43}$");
constexpr size_t kMaxSecretBytes = 65536;
constexpr LONGLONG kMaxCipherBytes = 131072;

struct HandleCloser {
  void operator()(void* handle) const noexcept {
    if (handle && handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
  }
};
using ScopedHandle = std::unique_ptr<void, HandleCloser>;

// DPAPI output must be released even if a subsequent allocation throws.
struct ScopedBlob {
  DATA_BLOB data{};
  ~ScopedBlob() {
    if (data.pbData) {
      SecureZeroMemory(data.pbData, data.cbData);
      LocalFree(data.pbData);
    }
  }
};

bool ValidSecret(const std::string& value) {
  return !value.empty() && value.size() <= kMaxSecretBytes &&
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), nullptr, 0) > 0;
}

bool MissingFile(DWORD error) {
  return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND;
}

std::string Argument(const Map& args, const char* key) {
  auto i = args.find(Value(key));
  if (i == args.end()) return {};
  const auto* s = std::get_if<std::string>(&i->second);
  return s ? *s : std::string();
}
std::filesystem::path SecretPath(const std::string& ref) {
  if (!std::regex_match(ref, kReference)) throw std::runtime_error("invalid-reference");
  PWSTR folder = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &folder)))
    throw std::runtime_error("unavailable");
  std::unique_ptr<wchar_t, decltype(&CoTaskMemFree)> owned_folder(folder,
                                                               CoTaskMemFree);
  std::filesystem::path dir(owned_folder.get());
  for (const auto* component : {L"SingLinkLabs", L"SingLinkVPN",
                                 L"ProtectedCredentials"}) {
    dir /= component;
    if (!CreateDirectoryW(dir.c_str(), nullptr) &&
        GetLastError() != ERROR_ALREADY_EXISTS)
      throw std::runtime_error("io");
    const auto attributes = GetFileAttributesW(dir.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        !(attributes & FILE_ATTRIBUTE_DIRECTORY) ||
        (attributes & FILE_ATTRIBUTE_REPARSE_POINT))
      throw std::runtime_error("io");
  }
  return dir / (ref + ".bin");
}
std::optional<std::string> Read(const std::string& ref) {
  auto path = SecretPath(ref);
  ScopedHandle file(CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
      nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (file.get() == INVALID_HANDLE_VALUE) {
    if (MissingFile(GetLastError())) return std::nullopt;
    throw std::runtime_error("io");
  }
  BY_HANDLE_FILE_INFORMATION info{};
  LARGE_INTEGER size{};
  if (!GetFileInformationByHandle(file.get(), &info) ||
      !GetFileSizeEx(file.get(), &size)) throw std::runtime_error("io");
  if ((info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY |
                                FILE_ATTRIBUTE_REPARSE_POINT)) ||
      size.QuadPart < 1 || size.QuadPart > kMaxCipherBytes)
    throw std::runtime_error("corrupt");
  std::vector<BYTE> data(static_cast<size_t>(size.QuadPart));
  DWORD count = 0;
  if (!ReadFile(file.get(), data.data(), static_cast<DWORD>(data.size()),
                &count, nullptr) || count != data.size())
    throw std::runtime_error("io");
  file.reset();
  DATA_BLOB encrypted{static_cast<DWORD>(data.size()), data.data()};
  DATA_BLOB entropy{static_cast<DWORD>(ref.size()),
                    reinterpret_cast<BYTE*>(const_cast<char*>(ref.data()))};
  ScopedBlob plain;
  if (!CryptUnprotectData(&encrypted, nullptr, &entropy, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &plain.data))
    throw std::runtime_error("locked");
  if (!plain.data.cbData || plain.data.cbData > kMaxSecretBytes)
    throw std::runtime_error("corrupt");
  std::string value(reinterpret_cast<char*>(plain.data.pbData), plain.data.cbData);
  if (!ValidSecret(value)) throw std::runtime_error("corrupt");
  return value;
}

HANDLE CreateCipherTemp(const std::filesystem::path& destination,
                        std::filesystem::path* temporary) {
  for (int attempt = 0; attempt != 8; ++attempt) {
    GUID id{};
    wchar_t suffix[40]{};
    if (FAILED(CoCreateGuid(&id)) || !StringFromGUID2(id, suffix, 40))
      throw std::runtime_error("unavailable");
    *temporary = destination;
    *temporary += L".tmp-";
    *temporary += suffix;
    HANDLE file = CreateFileW(temporary->c_str(), GENERIC_WRITE, 0, nullptr,
        CREATE_NEW, FILE_ATTRIBUTE_HIDDEN | FILE_FLAG_OPEN_REPARSE_POINT,
        nullptr);
    if (file != INVALID_HANDLE_VALUE) return file;
    if (GetLastError() != ERROR_FILE_EXISTS) throw std::runtime_error("io");
  }
  throw std::runtime_error("io");
}

void Write(const std::string& ref, const std::string& value) {
  if (!ValidSecret(value)) throw std::runtime_error("corrupt");
  auto path = SecretPath(ref);
  const auto previous = Read(ref);
  if (previous) {
    if (*previous != value) throw std::runtime_error("corrupt");
    return;
  }
  DATA_BLOB plain{static_cast<DWORD>(value.size()),
                  reinterpret_cast<BYTE*>(const_cast<char*>(value.data()))};
  DATA_BLOB entropy{static_cast<DWORD>(ref.size()),
                    reinterpret_cast<BYTE*>(const_cast<char*>(ref.data()))};
  ScopedBlob encrypted;
  // Default DPAPI scope is the current user, never LOCAL_MACHINE.
  if (!CryptProtectData(&plain, L"SingLinkVPN credential", &entropy, nullptr,
                        nullptr, CRYPTPROTECT_UI_FORBIDDEN, &encrypted.data))
    throw std::runtime_error("locked");
  std::filesystem::path temporary;
  HANDLE raw = CreateCipherTemp(path, &temporary);
  struct TempCleanup {
    const std::filesystem::path& path;
    ~TempCleanup() { DeleteFileW(path.c_str()); }
  } cleanup{temporary};
  ScopedHandle file(raw);
  DWORD total = 0;
  while (total < encrypted.data.cbData) {
    DWORD written = 0;
    if (!WriteFile(file.get(), encrypted.data.pbData + total,
                   encrypted.data.cbData - total, &written, nullptr) || !written)
      throw std::runtime_error("io");
    total += written;
  }
  if (!FlushFileBuffers(file.get())) throw std::runtime_error("io");
  file.reset();
  // Do not replace an existing immutable reference. A concurrent identical
  // write is idempotent; any other winner is an error, never an overwrite.
  if (!MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_WRITE_THROUGH)) {
    const auto winner = Read(ref);
    if (!winner || *winner != value) throw std::runtime_error("io");
  }
}

bool OwnedTemporaryName(const std::wstring& name, const std::wstring& prefix) {
  if (name.compare(0, prefix.size(), prefix) != 0) return false;
  const auto suffix = name.substr(prefix.size());
  if (suffix.size() != 38 || suffix.front() != L'{' || suffix.back() != L'}')
    return false;
  for (size_t i = 1; i < 37; ++i) {
    if (i == 9 || i == 14 || i == 19 || i == 24) {
      if (suffix[i] != L'-') return false;
    } else if (!((suffix[i] >= L'0' && suffix[i] <= L'9') ||
                 (suffix[i] >= L'a' && suffix[i] <= L'f') ||
                 (suffix[i] >= L'A' && suffix[i] <= L'F'))) {
      return false;
    }
  }
  return true;
}

void DeleteCipherFile(const std::filesystem::path& path) {
  const auto attributes = GetFileAttributesW(path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES) {
    if (MissingFile(GetLastError())) return;
    throw std::runtime_error("io");
  }
  // Never traverse links or recursively remove a directory during cleanup.
  if (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))
    throw std::runtime_error("io");
  if (!DeleteFileW(path.c_str()) && !MissingFile(GetLastError()))
    throw std::runtime_error("io");
}

void Delete(const std::string& ref) {
  const auto path = SecretPath(ref);
  DeleteCipherFile(path);
  auto legacy_tmp = path;
  legacy_tmp += L".tmp";
  DeleteCipherFile(legacy_tmp);
  const auto prefix = path.filename().wstring() + L".tmp-";
  for (const auto& entry : std::filesystem::directory_iterator(path.parent_path())) {
    if (OwnedTemporaryName(entry.path().filename().wstring(), prefix))
      DeleteCipherFile(entry.path());
  }
}
}  // namespace

CredentialStoreChannel::CredentialStoreChannel(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(messenger,
      "com.singlinklabs.singlinkvpn/secrets", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([](const flutter::MethodCall<Value>& call,
                                    std::unique_ptr<flutter::MethodResult<Value>> result) {
    const auto* args = std::get_if<Map>(call.arguments());
    if (!args) { result->Error("invalid-reference", "Invalid credential reference"); return; }
    const auto ref = Argument(*args, "reference");
    try {
      if (call.method_name() == "read") {
        auto value = Read(ref);
        result->Success(value ? Value(*value) : Value());
      } else if (call.method_name() == "write") {
        Write(ref, Argument(*args, "value")); result->Success();
      } else if (call.method_name() == "delete") {
        Delete(ref);
        result->Success();
      } else { result->NotImplemented(); }
    } catch (const std::exception& e) {
      const std::string code(e.what());
      const bool known = code == "invalid-reference" || code == "locked" ||
                         code == "corrupt" || code == "io";
      result->Error(known ? code : "unavailable", "Protected credential operation failed");
    }
  });
}
CredentialStoreChannel::~CredentialStoreChannel() {
  channel_->SetMethodCallHandler(nullptr);
}
