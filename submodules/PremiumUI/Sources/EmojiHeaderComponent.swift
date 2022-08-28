import Foundation
import UIKit
import Display
import ComponentFlow
import SwiftSignalKit
import SceneKit
import GZip
import AppBundle
import LegacyComponents
import AvatarNode
import AccountContext
import TelegramCore
import AnimationCache
import MultiAnimationRenderer
import EmojiStatusComponent

private let sceneVersion: Int = 3

class EmojiHeaderComponent: Component {
    let context: AccountContext
    let animationCache: AnimationCache
    let animationRenderer: MultiAnimationRenderer
    let placeholderColor: UIColor
    let fileId: Int64
    let isVisible: Bool
    let hasIdleAnimations: Bool
        
    init(
        context: AccountContext,
        animationCache: AnimationCache,
        animationRenderer: MultiAnimationRenderer,
        placeholderColor: UIColor,
        fileId: Int64,
        isVisible: Bool,
        hasIdleAnimations: Bool
    ) {
        self.context = context
        self.animationCache = animationCache
        self.animationRenderer = animationRenderer
        self.placeholderColor = placeholderColor
        self.fileId = fileId
        self.isVisible = isVisible
        self.hasIdleAnimations = hasIdleAnimations
    }
    
    static func ==(lhs: EmojiHeaderComponent, rhs: EmojiHeaderComponent) -> Bool {
        return lhs.placeholderColor == rhs.placeholderColor && lhs.fileId == rhs.fileId && lhs.isVisible == rhs.isVisible && lhs.hasIdleAnimations == rhs.hasIdleAnimations
    }
    
    final class View: UIView, SCNSceneRendererDelegate, ComponentTaggedView {
        final class Tag {
        }
        
        func matches(tag: Any) -> Bool {
            if let _ = tag as? Tag {
                return true
            }
            return false
        }
        
        private var _ready = Promise<Bool>(true)
        var ready: Signal<Bool, NoError> {
            return self._ready.get()
        }
        
        weak var animateFrom: UIView?
        weak var containerView: UIView?
        
        let statusView: ComponentHostView<Empty>
        
        private var hasIdleAnimations = false
        
        override init(frame: CGRect) {
            self.statusView = ComponentHostView<Empty>()
            
            super.init(frame: frame)
            
            self.addSubview(self.statusView)
                        
            self.disablesInteractiveModalDismiss = true
            self.disablesInteractiveTransitionGestureRecognizer = true
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
         
        func animateIn() {
            guard let animateFrom = self.animateFrom, var containerView = self.containerView else {
                return
            }
                        
            containerView = containerView.subviews[2].subviews[1]
            
            let initialPosition = self.statusView.center
            let targetPosition = self.statusView.superview!.convert(self.statusView.center, to: containerView)
            let sourcePosition = animateFrom.superview!.convert(animateFrom.center, to: containerView).offsetBy(dx: 0.0, dy: -20.0)
            
            containerView.addSubview(self.statusView)
            self.statusView.center = targetPosition
            
            animateFrom.alpha = 0.0
            self.statusView.layer.animateScale(from: 0.05, to: 1.0, duration: 0.55, timingFunction: kCAMediaTimingFunctionSpring)
            self.statusView.layer.animatePosition(from: sourcePosition, to: targetPosition, duration: 0.55, timingFunction: kCAMediaTimingFunctionSpring, completion: { _ in
                self.addSubview(self.statusView)
                self.statusView.center = initialPosition
            })
            
            Queue.mainQueue().after(0.4, {
                animateFrom.alpha = 1.0
            })
            
            self.animateFrom = nil
            self.containerView = nil
        }
        
        func update(component: EmojiHeaderComponent, availableSize: CGSize, transition: Transition) -> CGSize {
            self.hasIdleAnimations = component.hasIdleAnimations
            
            let size = self.statusView.update(
                transition: .immediate,
                component: AnyComponent(EmojiStatusComponent(
                    context: component.context,
                    animationCache: component.animationCache,
                    animationRenderer: component.animationRenderer,
                    content: .emojiStatus(
                        status: PeerEmojiStatus(fileId: component.fileId),
                        size: CGSize(width: 100.0, height: 100.0),
                        placeholderColor: component.placeholderColor
                    ),
                    action: nil,
                    longTapAction: nil
                )),
                environment: {},
                containerSize: CGSize(width: 96.0, height: 96.0)
            )
            self.statusView.frame = CGRect(origin: CGPoint(x: floorToScreenPixels((availableSize.width - size.width) / 2.0), y: 63.0), size: size)
            
            return availableSize
        }
    }
    
    func makeView() -> View {
        return View(frame: CGRect())
    }
    
    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: Transition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, transition: transition)
    }
}
