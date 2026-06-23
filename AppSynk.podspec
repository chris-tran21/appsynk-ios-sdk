Pod::Spec.new do |s|
  s.name             = 'AppSynk'
  s.version          = '1.0.1'
  s.summary          = 'AppSynk Mobile Attribution SDK (native iOS).'
  s.homepage         = 'https://appsynk.io'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'AppSynk' => 'contact@appsynk.io' }
  s.platform         = :ios, '14.0'
  s.swift_version    = '5.9'
  s.source           = { :git => 'https://github.com/appsynk/appsynk-ios-sdk.git', :tag => s.version }
  s.source_files     = 'Sources/AppSynk/**/*.swift'
  s.frameworks       = 'Foundation', 'UIKit', 'StoreKit', 'AppTrackingTransparency'
  s.weak_frameworks  = 'AdServices'
end
