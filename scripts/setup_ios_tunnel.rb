#!/usr/bin/env ruby
# Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
# SPDX-License-Identifier: Apache-2.0

# Adds the iOS device-wide VPN to ios/Runner.xcodeproj (idempotent):
#
#   * PacketTunnel app extension target (ios/PacketTunnel, Swift,
#     com.singlinklabs.singlinkvpn.tunnel) linking Singlink.xcframework
#   * Runner: links Singlink.xcframework too (Dart FFI finds SingLinkVersion /
#     SingLinkParseLink with DynamicLibrary.process()), SingLinkVpnPlugin.swift,
#     Runner.entitlements, "Embed Foundation Extensions" phase, iOS 15
#
# The framework comes from `make -C core ios` (core/build/apple/Singlink.xcframework).
#
# Needs the xcodeproj gem (no CocoaPods required):
#   gem install --install-dir "$GEM_DIR" xcodeproj
#   GEM_HOME="$GEM_DIR" GEM_PATH="$GEM_DIR" ruby scripts/setup_ios_tunnel.rb
require 'xcodeproj'

ROOT = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(ROOT, 'ios', 'Runner.xcodeproj')

APP_ID = 'com.singlinklabs.singlinkvpn'
EXT_NAME = 'PacketTunnel'
EXT_ID = "#{APP_ID}.tunnel"
IOS_MIN = '15.0'
XCFRAMEWORK = '../core/build/apple/Singlink.xcframework' # relative to ios/
# Exports the Runner must keep for dart:ffi (nothing in Swift references them,
# so without -u the static library member would not even be linked).
FFI_SYMBOLS = %w[
  SingLinkVersion SingLinkParseLink SingLinkStart SingLinkStop SingLinkStatus
  SingLinkProbe SingLinkExitIP SingLinkFree SingLinkTunStart SingLinkTunStop
  SingLinkSetMemoryLimit
].freeze
CORE_LDFLAGS = ['-framework', 'Security', '-framework', 'CoreFoundation'].freeze
SIM_EXCLUDED_ARCHS = 'i386 x86_64' # the core is built for arm64 simulators only

project = Xcodeproj::Project.open(PROJECT_PATH)
runner = project.targets.find { |t| t.name == 'Runner' } or abort 'Runner target not found'

def file_in(group, path)
  group.files.find { |f| f.path == path } || group.new_reference(path)
end

# --- shared framework reference -------------------------------------------
frameworks_group = project.frameworks_group
xcf = frameworks_group.files.find { |f| f.path == XCFRAMEWORK } ||
      frameworks_group.new_reference(XCFRAMEWORK, :project).tap do |r|
        r.name = 'Singlink.xcframework'
        r.last_known_file_type = 'wrapper.xcframework'
      end

# System frameworks relative to SDKROOT, so the project does not pin an SDK
# version (xcodeproj's add_system_framework writes iPhoneOS<ver>.sdk paths).
def sdk_framework(project, name)
  path = "System/Library/Frameworks/#{name}.framework"
  group = project.frameworks_group
  group.files.find { |f| f.path == path } ||
    group.new_reference(path, :sdk_root).tap { |r| r.name = "#{name}.framework" }
end
network_extension = sdk_framework(project, 'NetworkExtension')

# --- project-level deployment target --------------------------------------
project.build_configurations.each do |c|
  c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = IOS_MIN
end

# --- extension target -----------------------------------------------------
ext = project.targets.find { |t| t.name == EXT_NAME }
unless ext
  ext = project.new_target(:app_extension, EXT_NAME, :ios, IOS_MIN, nil, :swift)
  # Flutter builds Debug / Profile / Release.
  unless ext.build_configurations.any? { |c| c.name == 'Profile' }
    ext.add_build_configuration('Profile', :release)
  end
end

group = project.main_group.children.find { |g| g.respond_to?(:path) && g.path == EXT_NAME } ||
        project.main_group.new_group(EXT_NAME, EXT_NAME)
swift = file_in(group, 'PacketTunnelProvider.swift')
file_in(group, 'Info.plist')
file_in(group, 'PacketTunnel.entitlements')
file_in(group, 'PacketTunnel-Bridging-Header.h')
ext.source_build_phase.add_file_reference(swift, true)
ext.frameworks_build_phase.add_file_reference(xcf, true)
# new_target links Foundation by a versioned SDK path; Swift autolinks it.
ext.frameworks_build_phase.files.dup.each do |bf|
  next unless bf.file_ref && bf.file_ref.path.to_s.include?('.sdk/')
  ref = bf.file_ref
  ext.frameworks_build_phase.remove_build_file(bf)
  ref.remove_from_project if ref.build_files.empty?
end
project.frameworks_group.groups.each { |g| g.remove_from_project if g.children.empty? }
ext.frameworks_build_phase.add_file_reference(network_extension, true)

flutter_xcconfig = lambda do |config_name|
  file = config_name == 'Debug' ? 'Flutter/Debug.xcconfig' : 'Flutter/Release.xcconfig'
  project.files.find { |f| f.path == file }
end

runner_team = runner.build_configurations.map { |c| c.build_settings['DEVELOPMENT_TEAM'] }.compact.first

ext.build_configurations.each do |c|
  # Gives the extension FLUTTER_BUILD_NAME / NUMBER, so its version always
  # matches the app's (App Store requirement).
  c.base_configuration_reference = flutter_xcconfig.call(c.name)
  s = c.build_settings
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['PRODUCT_BUNDLE_IDENTIFIER'] = EXT_ID
  s['INFOPLIST_FILE'] = "#{EXT_NAME}/Info.plist"
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['CODE_SIGN_ENTITLEMENTS'] = "#{EXT_NAME}/PacketTunnel.entitlements"
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['DEVELOPMENT_TEAM'] = runner_team if runner_team
  s['SWIFT_OBJC_BRIDGING_HEADER'] = "#{EXT_NAME}/PacketTunnel-Bridging-Header.h"
  s['SWIFT_VERSION'] = '5.0'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = IOS_MIN
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  s['SKIP_INSTALL'] = 'YES'
  s['ENABLE_BITCODE'] = 'NO'
  s['CURRENT_PROJECT_VERSION'] = '$(FLUTTER_BUILD_NUMBER)'
  s['MARKETING_VERSION'] = '$(FLUTTER_BUILD_NAME)'
  s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks',
                                  '@executable_path/../../Frameworks']
  s['OTHER_LDFLAGS'] = ['$(inherited)'] + CORE_LDFLAGS
  # Xcode copies the xcframework's headers here; the second path is a
  # fallback for indexing before the first build.
  s['HEADER_SEARCH_PATHS'] = ['$(inherited)', '$(BUILT_PRODUCTS_DIR)/include',
                              "$(PROJECT_DIR)/#{XCFRAMEWORK}/ios-arm64/Headers"]
  s['EXCLUDED_ARCHS[sdk=iphonesimulator*]'] = SIM_EXCLUDED_ARCHS
  s['SWIFT_OPTIMIZATION_LEVEL'] = c.name == 'Debug' ? '-Onone' : '-O'
  s.delete('ASSETCATALOG_COMPILER_APPICON_NAME')
end

# --- Runner ---------------------------------------------------------------
runner_group = project.main_group.children.find { |g| g.respond_to?(:path) && g.path == 'Runner' } or
  abort 'Runner group not found'
plugin = file_in(runner_group, 'SingLinkVpnPlugin.swift')
file_in(runner_group, 'Runner.entitlements')
runner.source_build_phase.add_file_reference(plugin, true)
runner.frameworks_build_phase.add_file_reference(xcf, true)
runner.frameworks_build_phase.add_file_reference(network_extension, true)

ffi_flags = FFI_SYMBOLS.map { |s| "-Wl,-u,_#{s}" }
runner.build_configurations.each do |c|
  s = c.build_settings
  s['IPHONEOS_DEPLOYMENT_TARGET'] = IOS_MIN
  s['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
  s['OTHER_LDFLAGS'] = ['$(inherited)'] + CORE_LDFLAGS + ffi_flags
  # Archive builds strip the executable; keep the global SingLink* symbols
  # that dlsym (DynamicLibrary.process()) looks up.
  s['STRIP_STYLE'] = 'non-global'
  s['EXCLUDED_ARCHS[sdk=iphonesimulator*]'] = SIM_EXCLUDED_ARCHS
end

# Build the extension before the app and embed it into Runner.app/PlugIns.
runner.add_dependency(ext) unless runner.dependencies.any? { |d| d.target == ext }
embed = runner.copy_files_build_phases.find { |p| p.name == 'Embed Foundation Extensions' }
unless embed
  embed = runner.new_copy_files_build_phase('Embed Foundation Extensions')
  embed.symbol_dst_subfolder_spec = :plug_ins
end
unless embed.files_references.include?(ext.product_reference)
  bf = embed.add_file_reference(ext.product_reference, true)
  bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end
# Must run before Flutter's "Thin Binary" script, or Xcode reports a
# dependency cycle.
phases = runner.build_phases
thin = phases.find { |p| p.respond_to?(:name) && p.name == 'Thin Binary' }
if thin && phases.index(embed) > phases.index(thin)
  phases.delete(embed)
  phases.insert(phases.index(thin), embed)
end

# Keep the shared Runner scheme as is: it builds dependencies implicitly.
project.save
puts "[setup_ios_tunnel] #{PROJECT_PATH}: targets #{project.targets.map(&:name).join(', ')}"
