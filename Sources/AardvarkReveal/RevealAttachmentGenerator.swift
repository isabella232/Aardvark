//
//  Copyright 2020 Square, Inc.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Aardvark
import Foundation
import UIKit
import zlib

@objc(ARKRevealAttachmentGeneratorDelegate)
public protocol RevealAttachmentGeneratorDelegate: AnyObject {

    /// Called before the generator begins capture the current app state.
    ///
    /// This method will always be called on the main queue.
    func revealAttachmentGeneratorWillBeginCapturingAppState()

    /// Called after the generator attempts to capture the current app state.
    ///
    /// This method will always be called on the main queue.
    ///
    /// - parameter success: Whether the generator successfully captured the app state.
    func revealAttachmentGeneratorDidFinishCapturingAppState(success: Bool)

    /// Called after the generator captures a snapshot of the main screen.
    ///
    /// This method will always be called on the main queue.
    func revealAttachmentGeneratorDidCaptureMainScreenSnapshot()

    /// Called after the generator finishing bundling the reveal file.
    ///
    /// This method will always be called on the main queue.
    ///
    /// - parameter success: Whether the generator successfully bundled the Reveal file.
    func revealAttachmentGeneratorDidFinishBundlingRevealFile(success: Bool)

}

// MARK: -

/// Generator for a bug report attachment that contains a Reveal file showing a snapshot of the current application
/// state.
///
/// When the class is initialized, it will begin searching for a Reveal server running on the device. It is important to
/// allow the class some time between initialization and usage to search for the server.
///
/// To capture the current app state, call the `captureCurrentAppState(completionQueue:completion:)` method. The
/// completion will be called with a `nil` result if the attachment could not be generated (e.g. the Reveal server was
/// not found, a disk failure occured, etc.) or an attachment containing the contents of the Reveal file.
///
/// It is important to avoid changing the application state while the file is being generated, as the process involves
/// multiple asynchronous steps. The simplest way to do this is by disabling user interaction until the `completion` is
/// called. You can optionally specify a `delegate` to receive more detailed updated as to which phase the generator is
/// in, which allows for fine tuning the user experience.
///
/// ```text
///   ┌───────────────────────────────────────────────────────────┐
///   │                                                           │
///   │                Searching for Reveal Server                │
///   │                                                           │
///   └───────────────────────────────────────────────────────────┘
///                                 │                                      .───────────────────────────.
///                                 ├──────────────────────────────────▶  (       completion(nil)       )
///                                 │            Failed to                 `───────────────────────────'
///                           Found │          Locate Server
///                          Server │
///                                 │
///    .────────────────────────────┴────────────────────────────.
///   (    revealAttachmentGeneratorWillBeginCapturingAppState    )
///    `────────────────────────────┬────────────────────────────'
///                                 ▼
///   ┌───────────────────────────────────────────────────────────┐
///   │                                                           │
///   │                    Capturing App State                    │
///   │                                                           │
///   └───────────────────────────────────────────────────────────┘
///                                 │
///    .────────────────────────────┴────────────────────────────.
///   (    revealAttachmentGeneratorDidFinishCapturingAppState    )
///    `────────────────────────────┬────────────────────────────'
///                                 │                                      .───────────────────────────.
///                                 ├──────────────────────────────────▶  (       completion(nil)       )
///                                 │            Failed to                 `───────────────────────────'
///                        Captured │          Capture State
///                       App State │
///                                 ▼
///   ┌───────────────────────────────────────────────────────────┐
///   │                                                           │
///   │                    Capturing Snapshots                    │
///   │                                                           │
///   │  .─────────────────────────────────────────────────────.  │
///   │ ( revealAttachmentGeneratorDidCaptureMainScreenSnapshot ) │
///   │  `─────────────────────────────────────────────────────'  │
///   └───────────────────────────────────────────────────────────┘
///                                 │
///                                 ▼
///   ┌───────────────────────────────────────────────────────────┐
///   │                                                           │
///   │                   Bundling Reveal File                    │
///   │                                                           │
///   └───────────────────────────────────────────────────────────┘
///                                 │
///    .────────────────────────────┴────────────────────────────.
///   (   revealAttachmentGeneratorDidFinishBundlingRevealFile    )
///    `────────────────────────────┬────────────────────────────'
///                                 ▼
///                   .───────────────────────────.
///                  (         completion          )
///                   `───────────────────────────'
/// ```
///
/// It is important to avoid changing anything while the app state is being captured (during the `Capturing App State`
/// phase). Once the app state is captured, the generator will begin capturing snapshots of each drawable object (views,
/// layers, etc.) on the screen. Once the generator has captured a snapshot of the main screen (marked by a call to the
/// delegate's `revealAttachmentGeneratorDidCaptureMainScreenSnapshot` method), it is okay to display a waiting
/// indicator **as long as all of the existing views/layers remain in the hierarchy** (for example, you can display a
/// new window on top of the main window or present a modal view controller, depending on the use case). Once the
/// generator has completed bundling the Reveal file, user interaction can be restored.
@objc(ARKRevealAttachmentGenerator)
public final class RevealAttachmentGenerator: NSObject {

    // MARK: - Life Cycle

    public override init() {
        super.init()

        serviceBrowser.startSearching()

        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.serviceBrowser.stopSearching()
            }
        )

        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.serviceBrowser.startSearching()
            }
        )
    }

    deinit {
        notificationObservers.forEach(NotificationCenter.default.removeObserver(_:))
    }

    // MARK: - Public Properties

    public weak var delegate: RevealAttachmentGeneratorDelegate?

    // MARK: - Private Properties

    private let serviceBrowser: RevealServiceBrowser = .init()

    private var notificationObservers: [NSObjectProtocol] = []

    // MARK: - Public Methods

    /// Begins the process of capturing the current app state and bundling the results into an attachment containing a
    /// Reveal file.
    ///
    /// - parameter completionQueue: The queue on which to call the `completion`.
    /// - parameter completion: The completion handler to call when the capture is complete. Called with `nil` when the
    /// capture could not successfully be completed.
    @available(iOS 11, *)
    @objc
    public func captureCurrentAppState(
        completionQueue: DispatchQueue,
        completion: @escaping (ARKBugReportAttachment?) -> Void
    ) {
        guard let service = serviceBrowser.localService else {
            completionQueue.async {
                completion(nil)
            }
            return
        }

        let port = service.port
        guard port != -1 else {
            completionQueue.async {
                completion(nil)
            }
            return
        }

        let session = URLSession(configuration: .default)

        // We can always connect to Reveal on localhost, even if the service we discovered was using our host name.
        let baseRevealURL = URL(string: "http://localhost:\(port)")!

        delegate?.revealAttachmentGeneratorWillBeginCapturingAppState()

        let applicationURL = baseRevealURL.appendingPathComponent("application")
        let dataTask = session.dataTask(with: applicationURL) { [delegate] data, _, _ in
            guard let applicationStateData = data else {
                DispatchQueue.main.async {
                    delegate?.revealAttachmentGeneratorDidFinishCapturingAppState(success: false)
                }

                completionQueue.async {
                    completion(nil)
                }
                return
            }

            DispatchQueue.main.async {
                delegate?.revealAttachmentGeneratorDidFinishCapturingAppState(success: true)
            }

            do {
                let archiveBuilder = ARKRevealArchiveBuilder()

                try self.buildRevealPackage(
                    from: applicationStateData,
                    baseRevealURL: baseRevealURL,
                    urlSession: session,
                    archiveBuilder: archiveBuilder,
                    completionQueue: completionQueue
                ) { success in
                    guard
                        success,
                        let archive = archiveBuilder.completeArchive(),
                        let compressedArchive = ARKCompressionUtility.gzippedData(for: archive)
                    else {
                        DispatchQueue.main.async {
                            delegate?.revealAttachmentGeneratorDidFinishBundlingRevealFile(success:false)
                        }

                        completion(nil)
                        return
                    }

                    DispatchQueue.main.async {
                        delegate?.revealAttachmentGeneratorDidFinishBundlingRevealFile(success: true)
                    }

                    completion(
                        ARKBugReportAttachment(
                            fileName: "\(self.applicationName()).reveal.tar.gz",
                            data: compressedArchive,
                            dataMIMEType: "application/gzip"
                        )
                    )
                }

            } catch {
                DispatchQueue.main.async {
                    delegate?.revealAttachmentGeneratorDidFinishBundlingRevealFile(success: false)
                }

                completionQueue.async {
                    completion(nil)
                }
            }
        }

        dataTask.resume()
    }

    // MARK: - Private Methods

    @available(iOS 11, *)
    private func buildRevealPackage(
        from applicationStateData: Data,
        baseRevealURL: URL,
        urlSession: URLSession,
        archiveBuilder: ARKRevealArchiveBuilder,
        completionQueue: DispatchQueue,
        completion: @escaping (_ success: Bool) -> Void
    ) throws {
        // Create the bundle based on the application name, clamped to a reasonable length so that the file paths don't
        // go over 100 characters (a limitation of the archive builder).
        let appName = applicationName()
        let bundleName = "\(appName.prefix(50)).reveal"
        try archiveBuilder.addDirectory(atPath: "\(bundleName)/")

        if let compressedStateData = ARKCompressionUtility.gzippedData(for: applicationStateData) {
            try archiveBuilder.addFile(atPath: "\(bundleName)/ApplicationState.json.gz", with: compressedStateData)

        } else {
            completionQueue.async {
                completion(false)
            }
            return
        }

        try addPropertiesPlist(appName: appName, bundleName: bundleName, archiveBuilder: archiveBuilder)

        let resourceDirectoryName = "Resources"
        try archiveBuilder.addDirectory(atPath: "\(bundleName)/\(resourceDirectoryName)/")

        let applicationState = try JSONDecoder().decode(ApplicationState.self, from: applicationStateData)

        try archiveBuilder.addSymbolicLink(
            atPath: "\(bundleName)/Preview.png",
            toPath: "\(resourceDirectoryName)/\(applicationState.screens.mainScreen.identifier)#1.png"
        )

        var parametersForImageDownloads = try downloadTaskParametersForImages(
            in: applicationState,
            baseRevealURL: baseRevealURL,
            resourcesPathInArchive: "\(bundleName)/\(resourceDirectoryName)/"
        )

        var appIconURLRequest = URLRequest(url: baseRevealURL.appendingPathComponent("icon", isDirectory: false))
        appIconURLRequest.addValue("image/tiff", forHTTPHeaderField: "Accept")
        parametersForImageDownloads.append(
            DownloadTaskParameters(
                urlRequest: appIconURLRequest,
                pathInArchive: "\(bundleName)/Icon.tiff",
                completion: nil
            )
        )

        fetchImages(
            using: parametersForImageDownloads,
            urlSession: urlSession,
            archiveBuilder: archiveBuilder,
            completionQueue: completionQueue
        ) {
            completion(true)
        }
    }

    private struct DownloadTaskParameters {
        var urlRequest: URLRequest
        var pathInArchive: String
        var completion: (() -> Void)?
    }

    private func downloadTaskParametersForImages(
        in applicationState: ApplicationState,
        baseRevealURL: URL,
        resourcesPathInArchive: String
    ) throws -> [DownloadTaskParameters] {
        enum Error: Swift.Error {
            case failedToGenerateURL
        }

        func resourceImageParameters(for identifier: Int, showingSubviews: Bool) throws -> DownloadTaskParameters {
            let baseResourceURL = baseRevealURL
                .appendingPathComponent("objects", isDirectory: true)
                .appendingPathComponent("\(identifier)", isDirectory: false)

            guard var urlComponents = URLComponents(url: baseResourceURL, resolvingAgainstBaseURL: false) else {
                throw Error.failedToGenerateURL
            }
            urlComponents.query = "subviews=\(showingSubviews ? 1 : 0)"

            // This should never fail. The generated Reveal file is still valid even if it's missing the images though,
            // so continue to the next one rather than throwing an error.
            guard let imageURL = urlComponents.url else {
                throw Error.failedToGenerateURL
            }

            // Specify that we want a PNG representation of the object. Without this, the API defaults to returning a
            // JSON representation.
            var urlRequest = URLRequest(url: imageURL)
            urlRequest.addValue("image/png", forHTTPHeaderField: "Accept")

            let pathInArchive = resourcesPathInArchive.appending("\(identifier)#\(showingSubviews ? 1 : 0).png")

            return DownloadTaskParameters(urlRequest: urlRequest, pathInArchive: pathInArchive, completion: nil)
        }

        var taskParameters: [DownloadTaskParameters] = []

        let mainScreenIdentifier = applicationState.screens.mainScreen.identifier
        var mainScreenParameters = try resourceImageParameters(for: mainScreenIdentifier, showingSubviews: true)
        mainScreenParameters.completion = { [delegate] in
            DispatchQueue.main.async {
                delegate?.revealAttachmentGeneratorDidCaptureMainScreenSnapshot()
            }
        }
        taskParameters.append(mainScreenParameters)

        let identifiers = applicationState.application.identifiersForObjectsInHierachyWithImages()
        for identifier in identifiers {
            taskParameters.append(try resourceImageParameters(for: identifier, showingSubviews: false))
            taskParameters.append(try resourceImageParameters(for: identifier, showingSubviews: true))
        }

        return taskParameters
    }

    private func fetchImages(
        using taskParameters: [DownloadTaskParameters],
        urlSession: URLSession,
        archiveBuilder: ARKRevealArchiveBuilder,
        completionQueue: DispatchQueue,
        completion: @escaping () -> Void
    ) {
        let dispatchGroup = DispatchGroup()

        for parameters in taskParameters {
            dispatchGroup.enter()
            let task = urlSession.dataTask(with: parameters.urlRequest) { data, _, _ in
                // Try to add the data to the archive if we got valid data back. The Reveal file is still valid even if
                // it's missing some images, so don't throw any errors if this fails.
                if let data = data {
                    try? archiveBuilder.addFile(atPath: parameters.pathInArchive, with: data)
                }

                parameters.completion?()

                dispatchGroup.leave()
            }
            task.resume()
        }

        dispatchGroup.notify(queue: completionQueue) {
            completion()
        }
    }

    private func applicationName() -> String {
        return Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.localizedInfoDictionary?["CFBundleName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleName"] as? String
            ?? "Unknown App"
    }

    private func addPropertiesPlist(appName: String, bundleName: String, archiveBuilder: ARKRevealArchiveBuilder) throws {
        let propertiesPlist: [String: Any] = [
            "application-name": appName,
            "version": 2,
        ]
        let propertiesFileURL = URL(
            fileURLWithPath: (NSTemporaryDirectory() as NSString).appendingPathComponent("\(appName)-Properties.plist")
        )
        try (propertiesPlist as NSDictionary).write(to: propertiesFileURL)
        try archiveBuilder.addFile(
            atPath: "\(bundleName)/Properties.plist",
            with: try Data(contentsOf: propertiesFileURL)
        )
        try? FileManager.default.removeItem(at: propertiesFileURL)
    }

}

// MARK: -

extension Object {

    func identifiersForObjectsInHierachyWithImages() -> Set<Int> {
        var identifiers: Set<Int> = []

        if hasAssociatedImage() {
            identifiers.insert(self.identifier)
        }

        for attribute in attributes.values {
            switch attribute {
            case let .object(object):
                identifiers.formUnion(object.identifiersForObjectsInHierachyWithImages())

            case let .array(objects):
                for object in objects {
                    identifiers.formUnion(object.identifiersForObjectsInHierachyWithImages())
                }

            case .unknown:
                break
            }
        }

        return identifiers
    }

    private func hasAssociatedImage() -> Bool {
        return self.class.isTypeOf("UIView")
            || self.class.isTypeOf("CALayer")
            || self.class.isTypeOf("UIScreen")
    }

}
