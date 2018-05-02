// The MIT License (MIT)
//
// Copyright (c) 2015-2018 Alexander Grebenyuk (github.com/kean).

import Foundation

#if os(macOS)
import AppKit.NSImage
/// Alias for `NSImage`.
public typealias Image = NSImage
#else
import UIKit.UIImage
/// Alias for `UIImage`.
public typealias Image = UIImage
#endif

#if !os(watchOS)

#if os(macOS)
import Cocoa
/// Alias for `NSImageView`
public typealias ImageView = NSImageView
#else
import UIKit
/// Alias for `UIImageView`
public typealias ImageView = UIImageView
#endif

/// Loads an image into the given image view. For more info See the corresponding
/// `loadImage(with:options:into:)` method that works with `ImageRequest`.
/// - parameter completion: Completion handler to be called when the requests is
/// finished and image is displayed. `nil` by default.
@discardableResult
public func loadImage(with url: URL,
                      into view: ImageView,
                      progress: ImageTask.ProgressHandler? = nil,
                      completion: ImageTask.Completion? = nil) -> ImageTask? {
    return loadImage(with: ImageRequest(url: url), into: view, progress: progress, completion: completion)
}

/// Loads an image into the given image view. Cancels previous outstanding request
/// associated with the view.
/// - parameter completion: Completion handler to be called when the requests is
/// finished and image is displayed. `nil` by default.
///
/// If the image is stored in the memory cache, the image is displayed
/// immediately. The image is loaded using the pipeline object otherwise.
///
/// Nuke keeps a weak reference to the view. If the view is deallocated
/// the associated request automatically gets cancelled.
@discardableResult
public func loadImage(with request: ImageRequest,
                      into view: ImageView,
                      progress: ImageTask.ProgressHandler? = nil,
                      completion: ImageTask.Completion? = nil) -> ImageTask? {
    assert(Thread.isMainThread)

    let controller = ImageViewController.controller(for: view)
    controller.cancelOutstandingTask()

    let options = controller.options

    if options.isPrepareForReuseEnabled { // enabled by default
        #if os(macOS)
        view.layer?.removeAllAnimations()
        #else
        view.layer.removeAllAnimations()
        #endif
    }

    // Quick synchronous memory cache lookup
    if request.memoryCacheOptions.readAllowed,
        let imageCache = options.pipeline.configuration.imageCache,
        let response = imageCache.cachedResponse(for: request) {
        controller.handle(response: response, error: nil, fromMemCache: true)
        completion?(response, nil)
        return nil
    }

    // Display a placeholder.
    if let placeholder = options.placeholder {
        view.image = placeholder
        #if !os(macOS)
        if let contentMode = options.contentModes?.placeholder {
            view.contentMode = contentMode
        }
        #endif
    } else {
        if options.isPrepareForReuseEnabled {
            view.image = nil // Remove previously displayed images (if any)
        }
    }

    // Make sure that view reuse is handled correctly.
    controller.taskId += 1
    let taskId = controller.taskId

    // Start the request.
    // A delegate-based approach would probably work better here.
    controller.task = options.pipeline.loadImage(
        with: request,
        progress: {  [weak controller] (image, completed, total) in
            guard let controller = controller, controller.taskId == taskId else { return }
            controller.handle(partialImage: image)
            progress?(image, completed, total)
    },
        completion: { [weak controller] (response, error) in
            guard let controller = controller, controller.taskId == taskId else { return }
            controller.handle(response: response, error: error, fromMemCache: false)
            completion?(response, error)
    })
    return controller.task
}

/// Cancels an outstanding request associated with the view.
public func cancelRequest(for view: ImageView) {
    assert(Thread.isMainThread)
    ImageViewController.controller(for: view).cancelOutstandingTask()
}

// MARK: - ImageViewOptions

public struct ImageViewOptions {
    /// Placeholder to be set before loading an image. `nil` by default.
    public var placeholder: Image?

    /// The image transition animation performed when displaying a loaded image
    /// `.nil` by default.
    public var transition: Transition?

    /// Image to be displayd when request fails. `nil` by default.
    public var failureImage: Image?

    /// The image transition animation performed when displaying a failure image
    /// `.nil` by default.
    public var failureImageTransition: Transition?

    /// If true, every time you request a new image for a view, the view will be
    /// automatically prepared for reuse: image will be set to `nil`, and animations
    /// will be removed. `true` by default.
    public var isPrepareForReuseEnabled = true

    /// The pipeline to be used. `ImagePipeline.shared` by default.
    public var pipeline: ImagePipeline = ImagePipeline.shared

    #if !os(macOS)
    /// Custom content modes to be used when switching between images. It's very
    /// often when a "failure" image needs a `.center` mode when a "success" image
    /// needs something like `.scaleAspectFill`. `nil`  by default (don't change
    /// content mode).
    public var contentModes: ContentModes?

    public struct ContentModes {
        public var success: UIViewContentMode
        public var failure: UIViewContentMode
        public var placeholder: UIViewContentMode

        public init(success: UIViewContentMode, failure: UIViewContentMode, placeholder: UIViewContentMode) {
            self.success = success; self.failure = failure; self.placeholder = placeholder
        }
    }
    #endif

    public struct Transition {
        var style: Style

        struct Parameters {
            let duration: TimeInterval
            #if !os(macOS)
            let options: UIViewAnimationOptions
            #endif
        }

        enum Style {
            case fadeIn(parameters: Parameters)
            case custom((ImageView, Image) -> Void)
        }

        #if os(macOS)
        public static func fadeIn(duration: TimeInterval) -> Transition {
            return Transition(style: .fadeIn(parameters:  Parameters(duration: duration)))
        }
        #else
        public static func fadeIn(duration: TimeInterval, options: UIViewAnimationOptions = [.allowUserInteraction]) -> Transition {
            return Transition(style: .fadeIn(parameters:  Parameters(duration: duration, options: options)))
        }
        #endif

        public static func custom(_ closure: @escaping (ImageView, Image) -> Void) -> Transition {
            return Transition(style: .custom(closure))
        }
    }

    public init() {}
}

public extension ImageView {
    public var options: ImageViewOptions {
        get { return ImageViewController.controller(for: self).options }
        set { ImageViewController.controller(for: self).options = newValue }
    }
}

// MARK: - ImageViewController

// Controller is reused for multiple requests which makes sense, because in most
// cases image views are also going to be reused (e.g. cells in a table view).
private final class ImageViewController {
    unowned let imageView: ImageView
    weak var task: ImageTask?
    var taskId: Int = 0
    var options = ImageViewOptions()

    // Image view used for cross-fade transition between images with different
    // content modes.
    lazy var transitionImageView = ImageView()

    // Automatically cancel the request when the view is deallocated.
    deinit {
        cancelOutstandingTask()
    }

    init(view: /* unowned */ ImageView) {
        self.imageView = view
    }

    // MARK: - Associating Controller

    static var controllerAK = "ImageViewController.AssociatedKey"

    // Lazily create a controller for a given view and associate it with a view.
    static func controller(for view: ImageView) -> ImageViewController {
        if let controller = objc_getAssociatedObject(view, &ImageViewController.controllerAK) as? ImageViewController {
            return controller
        }
        let controller = ImageViewController(view: view)
        objc_setAssociatedObject(view, &ImageViewController.controllerAK, controller, .OBJC_ASSOCIATION_RETAIN)
        return controller
    }

    // MARK: - Managing Tasks

    func cancelOutstandingTask() {
        task?.cancel()
        task = nil
    }

    // MARK: - Handling Responses

    #if !os(macOS)

    func handle(response: ImageResponse?, error: Error?, fromMemCache: Bool) {
        if let image = response?.image {
            _display(image, options.transition, fromMemCache, options.contentModes?.success)
        } else if let failureImage = options.failureImage {
            _display(failureImage, options.failureImageTransition, fromMemCache, options.contentModes?.failure)
        }
        self.task = nil
    }

    func handle(partialImage image: Image?) {
        guard let image = image else { return }
        _display(image, options.transition, false, options.contentModes?.success)
    }

    #else

    func handle(response: ImageResponse?, error: Error?, fromMemCache: Bool) {
        // NSImageView doesn't support content mode, unfortunately.
        if let image = response?.image {
            _display(image, options.transition, fromMemCache, nil)
        } else if let failureImage = options.failureImage {
            _display(failureImage, options.failureImageTransition, fromMemCache, nil)
        }
        self.task = nil
    }

    func handle(partialImage image: Image?) {
        guard let image = image else { return }
        _display(image, options.transition, false, nil)
    }

    #endif

    private func _display(_ image: Image, _ transition: ImageViewOptions.Transition?, _ fromMemCache: Bool, _ newContentMode: _ContentMode?) {
        if !fromMemCache, let transition = transition {
            switch transition.style {
            case let .fadeIn(params):
                _runFadeInTransition(image: image, params: params, contentMode: newContentMode)
            case let .custom(closure):
                // The user is reponsible for both displaying an image and performing
                // animations.
                closure(imageView, image)
            }
        } else {
            imageView.image = image
        }
        #if !os(macOS)
        if let newContentMode = newContentMode {
            imageView.contentMode = newContentMode
        }
        #endif
    }

    // MARK: - Animations

    #if !os(macOS)

    private typealias _ContentMode = UIViewContentMode

    private func _runFadeInTransition(image: Image, params: ImageViewOptions.Transition.Parameters, contentMode: _ContentMode?) {
        // Special case where we animate between content modes.
        if let contentMode = contentMode, imageView.contentMode != contentMode, imageView.image != nil {
            _runCrossDissolveWithContentMode(image: image, params: params)
        } else {
            _runSimpleFadeIn(image: image, params: params)
        }
    }

    private func _runSimpleFadeIn(image: Image, params: ImageViewOptions.Transition.Parameters) {
        UIView.transition(
            with: imageView,
            duration: params.duration,
            options: params.options.union(.transitionCrossDissolve),
            animations: {
                self.imageView.image = image
        },
            completion: nil
        )
    }

    /// Performs cross-dissolve animation alonside transition to a new content
    /// mode. This isn't natively supported feature and it requires a second
    /// image view. There might be better ways to implement it.
    private func _runCrossDissolveWithContentMode(image: Image, params: ImageViewOptions.Transition.Parameters) {
        // Lazily create a transition view.
        let transitionView = self.transitionImageView

        // Create a transition view which mimics current view's contents.
        transitionView.image = imageView.image
        transitionView.contentMode = imageView.contentMode
        imageView.addSubview(transitionView)
        transitionView.frame = imageView.bounds

        // "Manual" cross-fade.
        transitionView.alpha = 1
        imageView.alpha = 0
        imageView.image = image // Display new image in current view

        UIView.animate(
            withDuration: params.duration,
            delay: 0,
            options: params.options,
            animations: {
                transitionView.alpha = 0
                self.imageView.alpha = 1
        },
            completion: { isCompleted in
                if isCompleted {
                    transitionView.removeFromSuperview()
                }
        })
    }

    #else

    private typealias _ContentMode = Void // There is no content mode on macOS

    private func _runFadeInTransition(image: Image, params: ImageViewOptions.Transition.Parameters, contentMode: _ContentMode?) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.duration = params.duration
        animation.fromValue = 0
        animation.toValue = 1
        imageView.layer?.add(animation, forKey: "imageTransition")
    }

    #endif
}

#endif