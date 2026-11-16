// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0
#ifndef RUNNER_CREDENTIAL_STORE_H_
#define RUNNER_CREDENTIAL_STORE_H_
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <memory>

class CredentialStoreChannel {
 public:
  explicit CredentialStoreChannel(flutter::BinaryMessenger* messenger);
  ~CredentialStoreChannel();
 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
#endif
