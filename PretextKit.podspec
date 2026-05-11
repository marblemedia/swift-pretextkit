Pod::Spec.new do |s|
  s.name = "PretextKit"
  s.version = "0.1.0"
  s.summary = "Deterministic text preparation and layout for Apple platforms."
  s.description = <<~DESC
    PretextKit provides the lower-level text preparation, segmentation,
    measurement, and layout engine used by PretextChatKit.
  DESC
  s.homepage = "https://github.com/mm-pretext/ios"
  s.license = { :type => "MIT" }
  s.author = { "Pretext" => "dev@pretext.local" }
  s.source = { :git => "https://github.com/mm-pretext/ios.git", :tag => s.version.to_s }

  s.ios.deployment_target = "15.8"
  s.osx.deployment_target = "13.0"
  s.swift_versions = ["5.9"]
  s.module_name = "PretextKit"

  s.source_files = "Sources/PretextKit/**/*.swift"
end
