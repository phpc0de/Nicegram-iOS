import Foundation
import AsyncDisplayKit
import Display
import TelegramCore
import SwiftSignalKit
import Postbox

final class MentionChatInputPanelItem: ListViewItem {
    fileprivate let account: Account
    fileprivate let peer: Peer
    private let peerSelected: (Peer) -> Void
    
    let selectable: Bool = true
    
    public init(account: Account, peer: Peer, peerSelected: @escaping (Peer) -> Void) {
        self.account = account
        self.peer = peer
        self.peerSelected = peerSelected
    }
    
    public func nodeConfiguredForWidth(async: @escaping (@escaping () -> Void) -> Void, width: CGFloat, previousItem: ListViewItem?, nextItem: ListViewItem?, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, () -> Void)) -> Void) {
        let configure = { () -> Void in
            let node = MentionChatInputPanelItemNode()
            
            let nodeLayout = node.asyncLayout()
            let (top, bottom) = (previousItem != nil, nextItem != nil)
            let (layout, apply) = nodeLayout(self, width, top, bottom)
            
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            
            completion(node, {
                return (nil, { apply(.None) })
            })
        }
        if Thread.isMainThread {
            async {
                configure()
            }
        } else {
            configure()
        }
    }
    
    public func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: ListViewItemNode, width: CGFloat, previousItem: ListViewItem?, nextItem: ListViewItem?, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping () -> Void) -> Void) {
        if let node = node as? MentionChatInputPanelItemNode {
            Queue.mainQueue().async {
                let nodeLayout = node.asyncLayout()
                
                async {
                    let (top, bottom) = (previousItem != nil, nextItem != nil)
                    
                    let (layout, apply) = nodeLayout(self, width, top, bottom)
                    Queue.mainQueue().async {
                        completion(layout, {
                            apply(animation)
                        })
                    }
                }
            }
        } else {
            assertionFailure()
        }
    }
    
    func selected(listView: ListView) {
        self.peerSelected(self.peer)
    }
}

private let avatarFont: UIFont = UIFont(name: "ArialRoundedMTBold", size: 16.0)!
private let textFont = Font.medium(14.0)

final class MentionChatInputPanelItemNode: ListViewItemNode {
    static let itemHeight: CGFloat = 42.0
    
    private let avatarNode: AvatarNode
    private let textNode: TextNode
    private let topSeparatorNode: ASDisplayNode
    private let separatorNode: ASDisplayNode
    private let highlightedBackgroundNode: ASDisplayNode
    
    init() {
        self.avatarNode = AvatarNode(font: avatarFont)
        self.textNode = TextNode()
        
        self.topSeparatorNode = ASDisplayNode()
        self.topSeparatorNode.backgroundColor = UIColor(rgb: 0xC9CDD1)
        self.topSeparatorNode.isLayerBacked = true
        
        self.separatorNode = ASDisplayNode()
        self.separatorNode.backgroundColor = UIColor(rgb: 0xD6D6DA)
        self.separatorNode.isLayerBacked = true
        
        self.highlightedBackgroundNode = ASDisplayNode()
        self.highlightedBackgroundNode.backgroundColor = UIColor(rgb: 0xd9d9d9)
        self.highlightedBackgroundNode.isLayerBacked = true
        
        super.init(layerBacked: false, dynamicBounce: false)
        
        self.backgroundColor = .white
        
        self.addSubnode(self.topSeparatorNode)
        self.addSubnode(self.separatorNode)
        
        self.addSubnode(self.avatarNode)
        self.addSubnode(self.textNode)
    }
    
    override public func layoutForWidth(_ width: CGFloat, item: ListViewItem, previousItem: ListViewItem?, nextItem: ListViewItem?) {
        if let item = item as? MentionChatInputPanelItem {
            let doLayout = self.asyncLayout()
            let merged = (top: previousItem != nil, bottom: nextItem != nil)
            let (layout, apply) = doLayout(item, width, merged.top, merged.bottom)
            self.contentSize = layout.contentSize
            self.insets = layout.insets
            apply(.None)
        }
    }
    
    func asyncLayout() -> (_ item: MentionChatInputPanelItem, _ width: CGFloat, _ mergedTop: Bool, _ mergedBottom: Bool) -> (ListViewItemNodeLayout, (ListViewItemUpdateAnimation) -> Void) {
        let makeTextLayout = TextNode.asyncLayout(self.textNode)
        return { [weak self] item, width, mergedTop, mergedBottom in
            let leftInset: CGFloat = 55.0
            let rightInset: CGFloat = 10.0
            
            let (textLayout, textApply) = makeTextLayout(NSAttributedString(string: item.peer.displayTitle, font: textFont, textColor: .black), nil, 1, .end, CGSize(width: width - leftInset - rightInset, height: 100.0), .natural, nil, UIEdgeInsets())
            
            let nodeLayout = ListViewItemNodeLayout(contentSize: CGSize(width: width, height: HashtagChatInputPanelItemNode.itemHeight), insets: UIEdgeInsets())
            
            return (nodeLayout, { _ in
                if let strongSelf = self {
                    strongSelf.avatarNode.setPeer(account: item.account, peer: item.peer)
                    
                    textApply()
                    
                    strongSelf.avatarNode.frame = CGRect(origin: CGPoint(x: 12.0, y: floor((nodeLayout.contentSize.height - 30.0) / 2.0)), size: CGSize(width: 30.0, height: 30.0))
                    strongSelf.textNode.frame = CGRect(origin: CGPoint(x: leftInset, y: floor((nodeLayout.contentSize.height - textLayout.size.height) / 2.0)), size: textLayout.size)
                    
                    strongSelf.topSeparatorNode.isHidden = mergedTop
                    strongSelf.separatorNode.isHidden = !mergedBottom
                    
                    strongSelf.topSeparatorNode.frame = CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: width, height: UIScreenPixel))
                    strongSelf.separatorNode.frame = CGRect(origin: CGPoint(x: leftInset, y: nodeLayout.contentSize.height - UIScreenPixel), size: CGSize(width: width - leftInset, height: UIScreenPixel))
                    
                    strongSelf.highlightedBackgroundNode.frame = CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: width, height: nodeLayout.size.height + UIScreenPixel))
                }
            })
        }
    }
    
    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        
        if highlighted {
            self.highlightedBackgroundNode.alpha = 1.0
            if self.highlightedBackgroundNode.supernode == nil {
                self.insertSubnode(self.highlightedBackgroundNode, aboveSubnode: self.separatorNode)
            }
        } else {
            if self.highlightedBackgroundNode.supernode != nil {
                if animated {
                    self.highlightedBackgroundNode.layer.animateAlpha(from: self.highlightedBackgroundNode.alpha, to: 0.0, duration: 0.4, completion: { [weak self] completed in
                        if let strongSelf = self {
                            if completed {
                                strongSelf.highlightedBackgroundNode.removeFromSupernode()
                            }
                        }
                    })
                    self.highlightedBackgroundNode.alpha = 0.0
                } else {
                    self.highlightedBackgroundNode.removeFromSupernode()
                }
            }
        }
    }
}
