#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint ares_bridge.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'ares_bridge'
  s.version          = '0.0.1'
  s.summary          = 'Cross-platform USB discovery and file transfer for Flutter.'
  s.description      = <<-DESC
Product-neutral USB peer discovery, sessions, and bidirectional file transfer.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }

  s.source           = { :path => '.' }
  s.source_files = 'ares_bridge/Sources/ares_bridge/**/*'

  # If your plugin requires a privacy manifest, for example if it collects user
  # data, update the PrivacyInfo.xcprivacy file to describe your plugin's
  # privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'ares_bridge_privacy' => ['ares_bridge/Sources/ares_bridge/PrivacyInfo.xcprivacy']}

  s.dependency 'FlutterMacOS'
  s.frameworks = 'CryptoKit', 'IOKit', 'IOUSBHost'

  s.platform = :osx, '10.15.4'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
