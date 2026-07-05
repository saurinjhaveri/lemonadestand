import Foundation
import Photos
import UIKit

/// Bridges Ray-Ban Meta glasses to the app WITHOUT the DAT SDK: photos taken
/// with the glasses' capture button sync (via the Meta AI app) into the iPhone
/// Camera Roll. We watch the photo library for new images that appear while a
/// session is active and hand them to the tour-guide pipeline automatically.
final class PhotoLibraryWatcher: NSObject, PHPhotoLibraryChangeObserver {
    /// Delivers a newly-added photo as JPEG. Called on the main queue.
    var onNewPhoto: ((Data) -> Void)?
    /// Fires the instant a new photo is detected, before its data loads — lets
    /// the app acknowledge immediately while the image is prepared.
    var onPhotoDetected: (() -> Void)?

    private var running = false
    private var since = Date.distantPast      // only photos newer than this
    private let imageManager = PHImageManager.default()

    /// Request access and begin watching. Returns false if access was denied.
    @discardableResult
    func start() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return false }
        guard !running else { return true }
        since = Date()                         // ignore everything already there
        running = true
        PHPhotoLibrary.shared().register(self)
        return true
    }

    func stop() {
        guard running else { return }
        running = false
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    // MARK: - PHPhotoLibraryChangeObserver

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        guard running else { return }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        opts.fetchLimit = 1
        guard let asset = PHAsset.fetchAssets(with: opts).firstObject,
              let created = asset.creationDate, created > since else { return }
        since = created
        DispatchQueue.main.async { self.onPhotoDetected?() }
        loadJPEG(from: asset)
    }

    private func loadJPEG(from asset: PHAsset) {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = true     // allow iCloud download if needed
        // The vision models need ~1MP, not the 12MP sensor image — asking Photos
        // for a downscaled render skips the full-size decode + our recompress,
        // shaving seconds off glasses→narration latency.
        let target = CGSize(width: 1280, height: 1280)
        imageManager.requestImage(for: asset, targetSize: target, contentMode: .aspectFit,
                                  options: opts) { [weak self] image, _ in
            guard let self, let jpeg = image?.jpegData(compressionQuality: 0.7) else { return }
            DispatchQueue.main.async { self.onNewPhoto?(jpeg) }
        }
    }
}
