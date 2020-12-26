//
//  ViewController.swift
//  ClawShopper
//
//  Created by Zheyuan Xu on 12/26/20.
//

import UIKit
import RealityKit
//import AVFoundation
import Vision
import ARKit
import SceneKit

class ViewController: UIViewController, ARSessionDelegate {
    var configuration = ARWorldTrackingConfiguration()
    
    @IBOutlet var arView: ARView!
    
    var isWatermellonAdded: Bool!
    var isShopEntered: Bool!
    
    var entryAnchor: Supermarket.Enter!
    var shelfAnchor: Supermarket.Scene!
    
    var cart: Entity!
    var cartPosition: SIMD3<Float>?
    
    var waterMellon: Entity!
    var waterMellonPosition: SIMD3<Float>!
    
    let cameraAnchor = AnchorEntity(.camera)
    //var pubnub: PubNub!
    //let channels = ["pubnub_onboarding_channel"]
    //let listener = SubscriptionListener(queue: .main)
    

    //private var cameraView: CameraView { view as! CameraView }
    
    private let videoDataOutputQueue = DispatchQueue(label: "CameraFeedDataOutput")
    //private var cameraFeedSession: AVCaptureSession?
    private var handPoseRequest = VNDetectHumanHandPoseRequest()
    
    private let drawOverlay = CAShapeLayer()
    private let drawPath = UIBezierPath()
    private var evidenceBuffer = [HandGestureProcessor.PointsPair]()
    private var lastDrawPoint: CGPoint?
    private var isFirstSegment = true
    private var lastObservationTimestamp = Date()
    
    private var gestureProcessor = HandGestureProcessor()
    
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        // Present an error message to the user
        print("Session failed. Changing worldAlignment property.")
        print(error.localizedDescription)

        if let arError = error as? ARError {
            switch arError.errorCode {
            case 102:
                configuration.worldAlignment = .gravity
                restartSessionWithoutDelete()
            default:
                restartSessionWithoutDelete()
            }
        }
    }
    
    func restartSessionWithoutDelete() {
        // Restart session with a different worldAlignment - prevents bug from crashing app
        self.arView.session.pause()

        self.arView.session.run(configuration, options: [
            .resetTracking,
            .removeExistingAnchors])
    }
    
    
    // function for handling tapping actions
    @objc
    func handleTap(recognizer: UITapGestureRecognizer) {
        entryAnchor.notifications.switchScene.post()
        isShopEntered = true
        arView.scene.anchors.append(shelfAnchor)
    }
    
    func setupARView() {
        arView.automaticallyConfigureSession = false
        //let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .automatic
        //arView.session.run(configuration)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        isWatermellonAdded = false
        isShopEntered = false
        //instantiation for pubnub API
//        listener.didReceiveMessage = { message in
//            print("[Message]: \(message)")
//        }
//        listener.didReceiveStatus = { status in
//            switch status {
//            case .success(let connection):
//                if connection == .connected {
//                    self.pubnub.publish(channel: self.channels[0], message: "Hello, PubNub Swift!") { result in
//                        print(result.map { "Publish Response at \($0.timetokenDate)" })
//                    }
//                }
//            case .failure(let error):
//                print("Status Error: \(error.localizedDescription)")
//            }
//        }
//
//        pubnub.publish(channel: self.channels[0], message: "Hello, PubNub Swift!", completion: nil)
//        DispatchQueue.main.async { [self] in
//            self.pubnub.add(self.listener)
//            self.pubnub.subscribe(to: self.channels, withPresence: true)
//        }
        
        
        handPoseRequest.maximumHandCount = 1
        // Add state change handler to hand gesture processor.
        gestureProcessor.didChangeStateClosure = { [weak self] state in
            self?.handleGestureStateChange(state: state)
        }
        // Add double tap gesture recognizer for clearing the draw path.
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        recognizer.numberOfTouchesRequired = 1
        recognizer.numberOfTapsRequired = 2
        arView.addGestureRecognizer(recognizer)
        
        // Load the "Box" scene from the "Experience" Reality File
        entryAnchor = try! Supermarket.loadEnter()
        shelfAnchor = try! Supermarket.loadScene()
        
        arView.scene.anchors.append(entryAnchor)
        
        cart = shelfAnchor.findEntity(named: "cart")
        waterMellon = shelfAnchor.findEntity(named: "watermellon1")
        
        //let cameraAnchor = AnchorEntity(.camera)
        
        
        cameraAnchor.addChild(cart)
        
        arView.scene.addAnchor(cameraAnchor)
        
        cart.transform.translation = [0, -1, -2]
        
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        
        arView.session.delegate = self
        setupARView()
        
        self.togglePeopleOcclusion()
        arView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(recognizer:))))
        
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        //cameraFeedSession?.stopRunning()
        super.viewWillDisappear(animated)
    }
    
    fileprivate func togglePeopleOcclusion() {
        guard let config = arView.session.configuration as? ARWorldTrackingConfiguration else {
            fatalError("Unexpectedly failed to get the configuration.")
        }
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) else {
            fatalError("People occlusion is not supported on this device.")
        }
        switch config.frameSemantics {
        case [.personSegmentationWithDepth]:
            config.frameSemantics.remove(.personSegmentationWithDepth)
        
        default:
            config.frameSemantics.insert(.personSegmentationWithDepth)
            
        }
        arView.session.run(config)
    }
    
    func processPoints(thumbTip: CGPoint?, indexTip: CGPoint?, ringTip: CGPoint?) {
        // Check that we have both points.
        guard let thumbPoint = thumbTip, let indexPoint = indexTip, let ringPoint = ringTip else {
            // If there were no observations for more than 2 seconds reset gesture processor.
            if Date().timeIntervalSince(lastObservationTimestamp) > 2 {
                gestureProcessor.reset()
            }
            //cameraView.showPoints([], color: .clear)
            return
        }
        
        // Convert points from AVFoundation coordinates to UIKit coordinates.
        //let previewLayer = cameraView.previewLayer
        //let thumbPointConverted = previewLayer.layerPointConverted(fromCaptureDevicePoint: thumbPoint)
        //let indexPointConverted = previewLayer.layerPointConverted(fromCaptureDevicePoint: indexPoint)
        //let ringPointConverted = previewLayer.layerPointConverted(fromCaptureDevicePoint: ringPoint)
        // Process new points
        //gestureProcessor.processPointsPair((thumbPointConverted, indexPointConverted, ringPointConverted))
    }
    
    private func handleGestureStateChange(state: HandGestureProcessor.State) {
        let pointsPair = gestureProcessor.lastProcessedPointsPair
        var tipsColor: UIColor
        switch state {
        case .possiblePinch, .possibleApart:
            // We are in one of the "possible": states, meaning there is not enough evidence yet to determine
            // if we want to draw or not. For now, collect points in the evidence buffer, so we can add them
            // to a drawing path when required.
            evidenceBuffer.append(pointsPair)
            tipsColor = .orange
        case .pinched:
            // We have enough evidence to draw. Draw the points collected in the evidence buffer, if any.
            for bufferedPoints in evidenceBuffer {
                updatePath(with: bufferedPoints, isLastPointsPair: false)
            }
            // Clear the evidence buffer.
            evidenceBuffer.removeAll()
            // Finally, draw the current point.
            updatePath(with: pointsPair, isLastPointsPair: false)
            tipsColor = .green
        case .apart, .unknown:
            // We have enough evidence to not draw. Discard any evidence buffer points.
            evidenceBuffer.removeAll()
            // And draw the last segment of our draw path.
            updatePath(with: pointsPair, isLastPointsPair: true)
            tipsColor = .red
        }
        //cameraView.showPoints([pointsPair.thumbTip, pointsPair.indexTip, pointsPair.ringTip], color: tipsColor)
    }
    
    private func updatePath(with points: HandGestureProcessor.PointsPair, isLastPointsPair: Bool) {
        // Get the mid point between the tips.
        let (thumbTip, indexTip, _) = points
        let drawPoint = CGPoint.midPoint(p1: thumbTip, p2: indexTip)

        if isLastPointsPair {
            if let lastPoint = lastDrawPoint {
                // Add a straight line from the last midpoint to the end of the stroke.
                //drawPath.addLine(to: lastPoint)
            }
            // We are done drawing, so reset the last draw point.
            //lastDrawPoint = nil
        } else {
            if lastDrawPoint == nil {
                // This is the beginning of the stroke.
                //drawPath.move(to: drawPoint)
                isFirstSegment = true
            } else {
                let lastPoint = lastDrawPoint!
                // Get the midpoint between the last draw point and the new point.
                let midPoint = CGPoint.midPoint(p1: lastPoint, p2: drawPoint)
                if isFirstSegment {
                    // If it's the first segment of the stroke, draw a line to the midpoint.
                    //drawPath.addLine(to: midPoint)
                    isFirstSegment = false
                } else {
                    // Otherwise, draw a curve to a midpoint using the last draw point as a control point.
                    //drawPath.addQuadCurve(to: midPoint, controlPoint: lastPoint)
                }
            }
            // Remember the last draw point for the next update pass.
            lastDrawPoint = drawPoint
        }
        // Update the path on the overlay layer.
        //drawOverlay.path = drawPath.cgPath
    }
    
    @IBAction func handleGesture(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else {
            return
        }
        evidenceBuffer.removeAll()
        //drawPath.removeAllPoints()
        //drawOverlay.path = drawPath.cgPath
    }
    
    
    
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        var middleTip: CGPoint?
        var indexTip: CGPoint?
        var ringTip: CGPoint?
        
        waterMellonPosition = SIMD3<Float>(
            waterMellon.position.x,
            waterMellon.position.y,
            waterMellon.position.z
        )
        
        let projectedPoint = arView.project(waterMellonPosition)
        let xPos = abs((projectedPoint?.x ?? 0) / 828)
        let yPos = abs((projectedPoint?.y ?? 0) / (1792 / 2))
        
        //print("watermellon coord x: \(xPos), y: \(yPos)")
        
        
        
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.capturedImage, orientation: .up, options: [:])
        do {
            try? handler.perform([handPoseRequest])
            guard let observation = handPoseRequest.results?.first as? VNRecognizedPointsObservation else {return}
            
            let middleFingerPoints = try! observation.recognizedPoints(forGroupKey: .handLandmarkRegionKeyMiddleFinger)
            let indexFingerPoints = try observation.recognizedPoints(forGroupKey: .handLandmarkRegionKeyIndexFinger)
            let ringFingerPoints = try observation.recognizedPoints(forGroupKey: .handLandmarkRegionKeyRingFinger)
            // Look for tip points.
            guard let middleTipPoint = middleFingerPoints[.handLandmarkKeyMiddleTIP], let indexTipPoint = indexFingerPoints[.handLandmarkKeyIndexTIP], let ringTipPoint = ringFingerPoints[.handLandmarkKeyRingTIP] else {
                return
            }
            // Ignore low confidence points.
            guard middleTipPoint.confidence > 0.3 && indexTipPoint.confidence > 0.3 &&  ringTipPoint.confidence > 0.3 else {
                return
            }
            // Convert points from Vision coordinates to AVFoundation coordinates.
            //pubnub.publish(channel: self.channels[0], message: "\(thumbTipPoint.location.x)", completion: nil)
            //print("middle finger x coord: \(middleTipPoint.location.x)")
            //print("middle finger y coord: \(1 - middleTipPoint.location.y)")
            
            
            
            
            
            middleTip = CGPoint(x: middleTipPoint.location.x, y: 1 - middleTipPoint.location.y)
            indexTip = CGPoint(x: indexTipPoint.location.x, y: 1 - indexTipPoint.location.y)
            ringTip = CGPoint(x: ringTipPoint.location.x, y: 1 - ringTipPoint.location.y)
            
            let diffXMiddle = abs(xPos - middleTipPoint.location.x)
            let diffYMiddle = abs(yPos - middleTipPoint.location.y)
            
            let diffMiddle = diffXMiddle + diffYMiddle
            
//            let diffMiddle = (pow(xPos - middleTipPoint.location.x, 2) + pow(yPos - (1 - middleTipPoint.location.y), 2)).squareRoot()
            
            //print("middle finger x: \(middleTipPoint.location.x) y: \(middleTipPoint.location.y)")
            print("difference middle: \(diffMiddle)")
            
            if (diffMiddle < 0.4) && !isWatermellonAdded && isShopEntered {
                print("condition met")
                isWatermellonAdded = true
                shelfAnchor.notifications.hide.post()
                cameraAnchor.addChild(waterMellon)
                waterMellon.transform.translation = [0, -0.3, -2]
            }
            
            
//            let cameraCoord = frame.camera.transform
//
//            let cameraPosition = SCNVector3(
//                cameraCoord.columns.3.x,
//                cameraCoord.columns.3.y,
//                cameraCoord.columns.3.z
//            )
//
            
//            cartPosition = cart.position
//
//            print("camera position: \(cameraPosition)")
//
//
//
//            print("cart position: \(cartPosition!)")
            
            
            

            
            
        } catch {
            //cameraFeedSession?.stopRunning()
            let error = AppError.visionError(error: error)
            DispatchQueue.main.async {
                error.displayInViewController(self)
            }
        }
    }
    
}


