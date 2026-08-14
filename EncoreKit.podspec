Pod::Spec.new do |s|
  s.name         = "EncoreKit"
  s.module_name  = "Encore"
  s.version      = "2.0.2"
  s.summary      = "Encore iOS SDK"
  s.homepage     = "https://github.com/EncoreKit/ios-sdk"
  s.license      = { :type => "Proprietary" }
  s.author       = { "Encore" => "support@encorekit.com" }
  s.source       = { :git => "https://github.com/EncoreKit/ios-sdk.git", :tag => "v#{s.version}" }
  s.ios.deployment_target = "15.0"
  s.swift_version = "5.9"
  s.source_files = "Sources/Encore/**/*.swift"

  s.dependency "swift-openapi-runtime", "~> 1.0"

  s.frameworks = "Foundation", "UIKit", "SwiftUI", "Combine", "StoreKit", "CryptoKit", "SafariServices", "AVKit"
end
