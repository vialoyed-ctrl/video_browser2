Pod::Spec.new do |s|
  s.name = 'MediaRemux'
  s.version = '1.0.0'
  s.summary = 'Local MPEG-TS to MP4 remuxing for Playback Warehouse.'
  s.homepage = 'https://github.com/vialoyed-ctrl/video_browser2'
  s.license = { :type => 'LGPL-2.1-or-later', :file => 'Vendor/LICENSE' }
  s.author = 'Playback Warehouse'
  s.source = { :path => '.' }
  s.platform = :ios, '16.0'
  s.source_files = 'Sources/*.{c,h}'
  s.public_header_files = 'Sources/VBMediaRemux.h'
  s.vendored_libraries = 'Vendor/lib/*.a'
  s.libraries = 'z', 'bz2', 'iconv'
  s.pod_target_xcconfig = { 'HEADER_SEARCH_PATHS' => '"${PODS_TARGET_SRCROOT}/Vendor/include"' }
end
