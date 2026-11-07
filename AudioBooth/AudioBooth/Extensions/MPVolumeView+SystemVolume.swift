import MediaPlayer
import UIKit

extension MPVolumeView {
  static func setSystemVolume(_ volume: Float) {
    let volumeView = MPVolumeView()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      let slider = volumeView.subviews.compactMap { $0 as? UISlider }.first
      slider?.value = volume
    }
  }
}
