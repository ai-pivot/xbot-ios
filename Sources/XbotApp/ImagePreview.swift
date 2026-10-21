import SwiftUI

struct ImagePreview: View {
    let image: UIImage
    let title: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZoomableImage(image: image).background(.black).ignoresSafeArea(edges: .bottom)
                .navigationTitle(title.nonEmpty ?? "图片").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() }.accessibilityIdentifier("image-preview-close") } }
        }.preferredColorScheme(.dark)
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> ImageScrollView { ImageScrollView(image: image) }
    func updateUIView(_ uiView: ImageScrollView, context: Context) {}
}

private final class ImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView: UIImageView
    private var lastSize: CGSize = .zero
    init(image: UIImage) {
        imageView = UIImageView(image: image)
        super.init(frame: .zero)
        delegate = self; backgroundColor = .black; bouncesZoom = true
        imageView.frame = CGRect(origin: .zero, size: image.size); addSubview(imageView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:))); tap.numberOfTapsRequired = 2; addGestureRecognizer(tap)
        accessibilityLabel = "图片预览，可双指缩放、拖动或双击缩放"
        accessibilityIdentifier = "image-zoom-canvas"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if bounds.size != lastSize {
            lastSize = bounds.size
            let size = imageView.image?.size ?? CGSize(width: 1, height: 1)
            let scale = min(bounds.width / max(1, size.width), bounds.height / max(1, size.height))
            minimumZoomScale = scale; maximumZoomScale = scale * 5; zoomScale = scale
        }
        centerImage()
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }
    private func centerImage() {
        contentInset = UIEdgeInsets(top: max(0, (bounds.height - contentSize.height) / 2), left: max(0, (bounds.width - contentSize.width) / 2), bottom: 0, right: 0)
    }
    @objc private func doubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale * 1.1 { setZoomScale(minimumZoomScale, animated: true); return }
        let scale = min(maximumZoomScale, minimumZoomScale * 3), point = gesture.location(in: imageView)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }
}
