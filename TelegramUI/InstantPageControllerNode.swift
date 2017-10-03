import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit
import AsyncDisplayKit
import Display
import SafariServices

final class InstantPageControllerNode: ASDisplayNode, UIScrollViewDelegate {
    private let account: Account
    private var settings: InstantPagePresentationSettings?
    private var presentationTheme: PresentationTheme
    private var strings: PresentationStrings
    private var theme: InstantPageTheme?
    private let present: (ViewController, Any?) -> Void
    private let openPeer: (PeerId) -> Void
    
    private var webPage: TelegramMediaWebpage?
    private var initialAnchor: String?
    
    private var containerLayout: ContainerViewLayout?
    private var setupScrollOffsetOnLayout: Bool = false
    
    private let statusBar: StatusBar
    private let navigationBar: InstantPageNavigationBar
    private let scrollNode: ASScrollNode
    private let scrollNodeHeader: ASDisplayNode
    private var linkHighlightingNode: LinkHighlightingNode?
    private var textSelectionNode: LinkHighlightingNode?
    private var settingsNode: InstantPageSettingsNode?
    private var settingsDimNode: ASDisplayNode?
    
    var currentLayout: InstantPageLayout?
    var currentLayoutTiles: [InstantPageTile] = []
    var currentLayoutItemsWithViews: [InstantPageItem] = []
    var distanceThresholdGroupCount: [Int: Int] = [:]
    
    var visibleTiles: [Int: InstantPageTileNode] = [:]
    var visibleItemsWithViews: [Int: InstantPageNode] = [:]
    
    var previousContentOffset: CGPoint?
    var isDeceleratingBecauseOfDragging = false
    
    private let hiddenMediaDisposable = MetaDisposable()
    private let resolveUrlDisposable = MetaDisposable()
    
    init(account: Account, settings: InstantPagePresentationSettings?, presentationTheme: PresentationTheme, strings: PresentationStrings, statusBar: StatusBar, present: @escaping (ViewController, Any?) -> Void, openPeer: @escaping (PeerId) -> Void, navigateBack: @escaping () -> Void) {
        self.account = account
        self.presentationTheme = presentationTheme
        self.strings = strings
        self.settings = settings
        self.theme = settings.flatMap(instantPageThemeForSettings)
        
        self.statusBar = statusBar
        self.present = present
        self.openPeer = openPeer
        
        self.navigationBar = InstantPageNavigationBar(strings: strings)
        self.scrollNode = ASScrollNode()
        self.scrollNodeHeader = ASDisplayNode()
        self.scrollNodeHeader.backgroundColor = .black
        
        super.init()
        
        self.setViewBlock({
            return UITracingLayerView()
        })
        
        if let theme = self.theme {
            self.backgroundColor = theme.pageBackgroundColor
        }
        self.addSubnode(self.scrollNode)
        self.scrollNode.addSubnode(self.scrollNodeHeader)
        self.addSubnode(self.navigationBar)
        self.scrollNode.view.delaysContentTouches = false
        self.scrollNode.view.delegate = self
        
        self.navigationBar.back = navigateBack
        self.navigationBar.share = { [weak self] in
            if let strongSelf = self, let webPage = strongSelf.webPage, case let .Loaded(content) = webPage.content {
                let shareController = ShareController(account: account, subject: .url(content.url))
                strongSelf.present(shareController, nil)
            }
        }
        self.navigationBar.settings = { [weak self] in
            if let strongSelf = self {
                strongSelf.presentSettings()
            }
        }
        self.navigationBar.scrollToTop = { [weak self] in
            if let strongSelf = self {
                strongSelf.scrollNode.view.setContentOffset(CGPoint(x: 0.0, y: -strongSelf.scrollNode.view.contentInset.top), animated: true)
            }
        }
    }
    
    deinit {
        self.hiddenMediaDisposable.dispose()
        self.resolveUrlDisposable.dispose()
    }
    
    func update(settings: InstantPagePresentationSettings, strings: PresentationStrings) {
        if self.settings != settings || self.strings !== strings {
            let previousSettings = self.settings
            var updateLayout = previousSettings == nil
            
            self.settings = settings
            let theme = instantPageThemeForSettings(settings)
            self.theme = theme
            self.strings = strings
            
            var animated = false
            if let previousSettings = previousSettings {
                if previousSettings.themeType != settings.themeType {
                    updateLayout = true
                    animated = true
                }
                if previousSettings.fontSize != settings.fontSize || previousSettings.forceSerif != settings.forceSerif {
                    animated = false
                    updateLayout = true
                }
            }
            
            self.backgroundColor = theme.pageBackgroundColor
            
            if updateLayout {
                if animated {
                    if let snapshotView = self.scrollNode.view.snapshotView(afterScreenUpdates: false) {
                        self.view.insertSubview(snapshotView, aboveSubview: self.scrollNode.view)
                        snapshotView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false, completion: { [weak snapshotView] _ in
                            snapshotView?.removeFromSuperview()
                        })
                    }
                }
                
                self.updateLayout()
                
                for (_, itemNode) in self.visibleItemsWithViews {
                    itemNode.update(strings: strings, theme: theme)
                }
                
                self.updateVisibleItems()
                self.updateNavigationBar()
                
                self.recursivelyEnsureDisplaySynchronously(true)
            }
        }
    }
    
    override func didLoad() {
        super.didLoad()
        
        if #available(iOSApplicationExtension 11.0, *) {
            self.scrollNode.view.contentInsetAdjustmentBehavior = .never
        }
        
        let recognizer = TapLongTapOrDoubleTapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:)))
        recognizer.delaysTouchesBegan = false
        recognizer.tapActionAtPoint = { [weak self] point in
            if let strongSelf = self {
                if let currentLayout = strongSelf.currentLayout {
                    for item in currentLayout.items {
                        if item.frame.contains(point) {
                            if item is InstantPagePeerReferenceItem {
                                return .fail
                            } else if item is InstantPageAudioItem {
                                return .fail
                            }
                            break
                        }
                    }
                }
            }
            return .waitForSingleTap
        }
        recognizer.highlight = { [weak self] point in
            if let strongSelf = self {
                strongSelf.updateTouchesAtPoint(point)
            }
        }
        self.scrollNode.view.addGestureRecognizer(recognizer)
    }
    
    func updateWebPage(_ webPage: TelegramMediaWebpage?, anchor: String?) {
        if self.webPage != webPage {
            self.setupScrollOffsetOnLayout = self.webPage == nil
            self.webPage = webPage
            self.initialAnchor = anchor
            
            self.currentLayout = nil
            self.updateLayout()
            
            self.scrollNode.frame = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
            if let containerLayout = self.containerLayout {
                self.containerLayoutUpdated(containerLayout, navigationBarHeight: 0.0, transition: .immediate)
            }
        }
    }
    
    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        self.containerLayout = layout
        
        if let settingsDimNode = self.settingsDimNode {
            transition.updateFrame(node: settingsDimNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        }
        
        if let settingsNode = self.settingsNode {
            settingsNode.updateLayout(layout: layout, transition: transition)
            transition.updateFrame(node: settingsNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        }
        
        let statusBarHeight: CGFloat = layout.statusBarHeight ?? 0.0
        let scrollInsetTop = 44.0 + statusBarHeight
        
        let resetOffset = self.scrollNode.bounds.size.width.isZero || self.setupScrollOffsetOnLayout
        let widthUpdated = !self.scrollNode.bounds.size.width.isEqual(to: layout.size.width)
        
        var shouldUpdateVisibleItems = false
        if self.scrollNode.bounds.size != layout.size || !self.scrollNode.view.contentInset.top.isEqual(to: scrollInsetTop) {
            self.scrollNode.frame = CGRect(x: 0.0, y: 0.0, width: layout.size.width, height: layout.size.height)
            self.scrollNodeHeader.frame = CGRect(origin: CGPoint(x: 0.0, y: -2000.0), size: CGSize(width: layout.size.width, height: 2000.0))
            self.scrollNode.view.contentInset = UIEdgeInsetsMake(scrollInsetTop, 0.0, 0.0, 0.0)
            if widthUpdated {
                self.updateLayout()
            }
            shouldUpdateVisibleItems = true
            self.updateNavigationBar()
        }
        if resetOffset {
            var contentOffset = CGPoint(x: 0.0, y: -self.scrollNode.view.contentInset.top)
            if let anchor = self.initialAnchor, let items = self.currentLayout?.items {
                self.setupScrollOffsetOnLayout = false
                if !anchor.isEmpty {
                    outer: for item in items {
                        if let item = item as? InstantPageAnchorItem, item.anchor == anchor {
                            contentOffset = CGPoint(x: 0.0, y: item.frame.origin.y - self.scrollNode.view.contentInset.top)
                            break outer
                        }
                    }
                }
            }
            self.scrollNode.view.contentOffset = contentOffset
        }
        if shouldUpdateVisibleItems {
            self.updateVisibleItems()
        }
    }
    
    private func updateLayout() {
        guard let containerLayout = self.containerLayout, let webPage = self.webPage, let theme = self.theme else {
            return
        }
        
        let currentLayout = instantPageLayoutForWebPage(webPage, boundingWidth: containerLayout.size.width, strings: self.strings, theme: theme)
        
        for (_, tileNode) in self.visibleTiles {
            tileNode.removeFromSupernode()
        }
        self.visibleTiles.removeAll()
        
        let currentLayoutTiles = instantPageTilesFromLayout(currentLayout, boundingWidth: containerLayout.size.width)
        
        var currentLayoutItemsWithViews: [InstantPageItem] = []
        var distanceThresholdGroupCount: [Int: Int] = [:]
        
        for item in currentLayout.items {
            if item.wantsNode {
                currentLayoutItemsWithViews.append(item)
                if let group = item.distanceThresholdGroup() {
                    let count: Int
                    if let currentCount = distanceThresholdGroupCount[Int(group)] {
                        count = currentCount
                    } else {
                        count = 0
                    }
                    distanceThresholdGroupCount[Int(group)] = count + 1
                }
            }
        }
        
        self.currentLayout = currentLayout
        self.currentLayoutTiles = currentLayoutTiles
        self.currentLayoutItemsWithViews = currentLayoutItemsWithViews
        self.distanceThresholdGroupCount = distanceThresholdGroupCount
        
        self.scrollNode.view.contentSize = currentLayout.contentSize
    }
    
    func updateVisibleItems() {
        guard let theme = self.theme else {
            return
        }
        
        var visibleTileIndices = Set<Int>()
        var visibleItemIndices = Set<Int>()
        
        let visibleBounds = self.scrollNode.view.bounds
        
        var topNode: ASDisplayNode?
        for node in self.scrollNode.subnodes.reversed() {
            if let node = node as? InstantPageTileNode {
                topNode = node
                break
            }
        }
        
        var tileIndex = -1
        for tile in self.currentLayoutTiles {
            tileIndex += 1
            var tileVisibleFrame = tile.frame
            tileVisibleFrame.origin.y -= 400.0
            tileVisibleFrame.size.height += 400.0 * 2.0
            if tileVisibleFrame.intersects(visibleBounds) {
                visibleTileIndices.insert(tileIndex)
                
                if visibleTiles[tileIndex] == nil {
                    let tileNode = InstantPageTileNode(tile: tile, backgroundColor: theme.pageBackgroundColor)
                    tileNode.frame = tile.frame
                    if let topNode = topNode {
                        self.scrollNode.insertSubnode(tileNode, aboveSubnode: topNode)
                    } else {
                        self.scrollNode.insertSubnode(tileNode, at: 0)
                    }
                    topNode = tileNode
                    self.visibleTiles[tileIndex] = tileNode
                }
            }
        }
        
        var itemIndex = -1
        for item in self.currentLayoutItemsWithViews {
            itemIndex += 1
            var itemThreshold: CGFloat = 0.0
            if let group = item.distanceThresholdGroup() {
                var count: Int = 0
                if let currentCount = self.distanceThresholdGroupCount[group] {
                    count = currentCount
                }
                itemThreshold = item.distanceThresholdWithGroupCount(count)
            }
            var itemFrame = item.frame
            itemFrame.origin.y -= itemThreshold
            itemFrame.size.height += itemThreshold * 2.0
            if visibleBounds.intersects(itemFrame) {
                visibleItemIndices.insert(itemIndex)
                
                var itemNode = self.visibleItemsWithViews[itemIndex]
                if let currentItemNode = itemNode {
                    if !item.matchesNode(currentItemNode) {
                        (currentItemNode as! ASDisplayNode).removeFromSupernode()
                        self.visibleItemsWithViews.removeValue(forKey: itemIndex)
                        itemNode = nil
                    }
                }
                
                if itemNode == nil {
                    if let itemNode = item.node(account: self.account, strings: self.strings, theme: theme, openMedia: { [weak self] media in
                        self?.openMedia(media)
                    }, openPeer: { [weak self] peerId in
                        self?.openPeer(peerId)
                    }) {
                        (itemNode as! ASDisplayNode).frame = item.frame
                        if let topNode = topNode {
                            self.scrollNode.insertSubnode(itemNode as! ASDisplayNode, aboveSubnode: topNode)
                        } else {
                            self.scrollNode.insertSubnode(itemNode as! ASDisplayNode, at: 0)
                        }
                        topNode = itemNode as! ASDisplayNode
                        self.visibleItemsWithViews[itemIndex] = itemNode
                    }
                } else {
                    if (itemNode as! ASDisplayNode).frame != item.frame {
                        (itemNode as! ASDisplayNode).frame = item.frame
                    }
                }
            }
        }
        
        var removeTileIndices: [Int] = []
        for (index, tileNode) in self.visibleTiles {
            if !visibleTileIndices.contains(index) {
                removeTileIndices.append(index)
                tileNode.removeFromSupernode()
            }
        }
        for index in removeTileIndices {
            self.visibleTiles.removeValue(forKey: index)
        }
        
        var removeItemIndices: [Int] = []
        for (index, itemNode) in self.visibleItemsWithViews {
            if !visibleItemIndices.contains(index) {
                removeItemIndices.append(index)
                (itemNode as! ASDisplayNode).removeFromSupernode()
            } else {
                var itemFrame = (itemNode as! ASDisplayNode).frame
                let itemThreshold: CGFloat = 200.0
                itemFrame.origin.y -= itemThreshold
                itemFrame.size.height += itemThreshold * 2.0
                itemNode.updateIsVisible(visibleBounds.intersects(itemFrame))
            }
        }
        for index in removeItemIndices {
            self.visibleItemsWithViews.removeValue(forKey: index)
        }
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        self.updateVisibleItems()
        self.updateNavigationBar()
        self.previousContentOffset = self.scrollNode.view.contentOffset
    }
    
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        self.isDeceleratingBecauseOfDragging = decelerate
        if !decelerate {
            self.updateNavigationBar(forceState: true)
        }
    }
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        self.updateNavigationBar(forceState: true)
        self.isDeceleratingBecauseOfDragging = false
    }
    
    func updateNavigationBar(forceState: Bool = false) {
        let bounds = self.scrollNode.view.bounds
        let contentOffset = self.scrollNode.view.contentOffset
        
        var pageProgress: CGFloat = 0.0
        if !self.scrollNode.view.contentSize.height.isZero {
            let value = (contentOffset.y + self.scrollNode.view.contentInset.top) / (self.scrollNode.view.contentSize.height - bounds.size.height + self.scrollNode.view.contentInset.top)
            pageProgress = max(0.0, min(1.0, value))
        }
        
        let delta: CGFloat
        if let previousContentOffset = self.previousContentOffset {
            delta = contentOffset.y - previousContentOffset.y
        } else {
            delta = 0.0
        }
        self.previousContentOffset = contentOffset
        
        var transition: ContainedViewLayoutTransition = .immediate
        var navigationBarFrame = self.navigationBar.frame
        navigationBarFrame.size.width = bounds.size.width
        if navigationBarFrame.size.height.isZero {
            navigationBarFrame.size.height = 64.0
        }
        if forceState {
            transition = .animated(duration: 0.3, curve: .spring)
            
            if contentOffset.y <= -self.scrollNode.view.contentInset.top || CGFloat(32.0).isLess(than: navigationBarFrame.size.height) {
                navigationBarFrame.size.height = 64.0
            } else {
                navigationBarFrame.size.height = 20.0
            }
        } else {
            if contentOffset.y <= -self.scrollNode.view.contentInset.top {
                navigationBarFrame.size.height = 64.0
            } else {
                navigationBarFrame.size.height -= delta
            }
            navigationBarFrame.size.height = max(20.0, min(64.0, navigationBarFrame.size.height))
        }
        
        if navigationBarFrame.height.isEqual(to: 64.0) {
            assert(true)
        }
        
        var statusBarAlpha = min(1.0, max(0.0, (navigationBarFrame.size.height - 20.0) / 44.0))
        transition.updateAlpha(node: self.statusBar, alpha: statusBarAlpha * statusBarAlpha)
        self.statusBar.verticalOffset = navigationBarFrame.size.height - 64.0
        
        transition.updateFrame(node: self.navigationBar, frame: navigationBarFrame)
        self.navigationBar.updateLayout(size: navigationBarFrame.size, pageProgress: pageProgress, transition: transition)
        
        transition.animateView {
            self.scrollNode.view.scrollIndicatorInsets = UIEdgeInsets(top: navigationBarFrame.size.height, left: 0.0, bottom: 0.0, right: 0.0)
        }
    }
    
    private func updateTouchesAtPoint(_ location: CGPoint?) {
        var rects: [CGRect]?
        if let location = location, let currentLayout = self.currentLayout {
            for item in currentLayout.items {
                if item.frame.contains(location) {
                    let textNodeFrame = item.frame
                    var itemRects = item.linkSelectionRects(at: location.offsetBy(dx: -item.frame.minX, dy: -item.frame.minY))
                    for i in 0 ..< itemRects.count {
                        itemRects[i] = itemRects[i].offsetBy(dx: textNodeFrame.minX, dy: textNodeFrame.minY).insetBy(dx: -2.0, dy: -2.0)
                    }
                    if !itemRects.isEmpty {
                        rects = itemRects
                        break
                    }
                }
            }
        }
        
        if let rects = rects {
            let linkHighlightingNode: LinkHighlightingNode
            if let current = self.linkHighlightingNode {
                linkHighlightingNode = current
            } else {
                linkHighlightingNode = LinkHighlightingNode(color: UIColor(rgb: 0x007BE8).withAlphaComponent(0.4))
                linkHighlightingNode.isUserInteractionEnabled = false
                self.linkHighlightingNode = linkHighlightingNode
                self.scrollNode.addSubnode(linkHighlightingNode)
            }
            linkHighlightingNode.frame = CGRect(origin: CGPoint(), size: self.scrollNode.bounds.size)
            linkHighlightingNode.updateRects(rects)
        } else if let linkHighlightingNode = self.linkHighlightingNode {
            self.linkHighlightingNode = nil
            linkHighlightingNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.18, removeOnCompletion: false, completion: { [weak linkHighlightingNode] _ in
                linkHighlightingNode?.removeFromSupernode()
            })
        }
    }
    
    private func textItemAtLocation(_ location: CGPoint) -> InstantPageTextItem? {
        if let currentLayout = self.currentLayout {
            for item in currentLayout.items {
                if let item = item as? InstantPageTextItem, item.frame.contains(location) {
                    return item
                }
            }
        }
        return nil
    }
    
    private func urlForTapLocation(_ location: CGPoint) -> InstantPageUrlItem? {
        if let item = self.textItemAtLocation(location) {
            return item.urlAttribute(at: location.offsetBy(dx: -item.frame.minX, dy: -item.frame.minY))
        }
        return nil
    }
    
    @objc private func tapGesture(_ recognizer: TapLongTapOrDoubleTapGestureRecognizer) {
        switch recognizer.state {
            case .ended:
                if let (gesture, location) = recognizer.lastRecognizedGestureAndLocation {
                    switch gesture {
                        case .tap:
                            if let url = self.urlForTapLocation(location) {
                                self.openUrl(url)
                            }
                        case .longTap:
                            if let url = self.urlForTapLocation(location) {
                                let actionSheet = ActionSheetController(presentationTheme: self.presentationTheme)
                                actionSheet.setItemGroups([ActionSheetItemGroup(items: [
                                    ActionSheetTextItem(title: url.url),
                                    ActionSheetButtonItem(title: self.self.strings.Conversation_LinkDialogOpen, color: .accent, action: { [weak self, weak actionSheet] in
                                        actionSheet?.dismissAnimated()
                                        if let strongSelf = self {
                                            strongSelf.openUrl(url)
                                        }
                                    }),
                                    ActionSheetButtonItem(title: self.strings.Web_CopyLink, color: .accent, action: { [weak actionSheet] in
                                        actionSheet?.dismissAnimated()
                                        UIPasteboard.general.string = url.url
                                    }),
                                    ActionSheetButtonItem(title: self.strings.Conversation_AddToReadingList, color: .accent, action: { [weak actionSheet] in
                                        actionSheet?.dismissAnimated()
                                        if let link = URL(string: url.url) {
                                            let _ = try? SSReadingList.default()?.addItem(with: link, title: nil, previewText: nil)
                                        }
                                    })
                                ]), ActionSheetItemGroup(items: [
                                    ActionSheetButtonItem(title: self.strings.Common_Cancel, color: .accent, action: { [weak actionSheet] in
                                        actionSheet?.dismissAnimated()
                                    })
                                ])])
                                self.present(actionSheet, nil)
                            } else if let item = self.textItemAtLocation(location) {
                                let textNodeFrame = item.frame
                                var itemRects = item.lineRects()
                                for i in 0 ..< itemRects.count {
                                    itemRects[i] = itemRects[i].offsetBy(dx: textNodeFrame.minX, dy: textNodeFrame.minY).insetBy(dx: -2.0, dy: -2.0)
                                }
                                self.updateTextSelectionRects(itemRects, text: item.plainText())
                            }
                        default:
                            break
                    }
                }
            default:
                break
        }
    }
    
    private func updateTextSelectionRects(_ rects: [CGRect], text: String?) {
        if let text = text, !rects.isEmpty {
            let textSelectionNode: LinkHighlightingNode
            if let current = self.textSelectionNode {
                textSelectionNode = current
            } else {
                textSelectionNode = LinkHighlightingNode(color: UIColor.lightGray.withAlphaComponent(0.4))
                textSelectionNode.isUserInteractionEnabled = false
                self.textSelectionNode = textSelectionNode
                self.scrollNode.addSubnode(textSelectionNode)
            }
            textSelectionNode.frame = CGRect(origin: CGPoint(), size: self.scrollNode.bounds.size)
            textSelectionNode.updateRects(rects)
            
            var coveringRect = rects[0]
            for i in 1 ..< rects.count {
                coveringRect = coveringRect.union(rects[i])
            }
            
            let controller = ContextMenuController(actions: [ContextMenuAction(content: .text(self.strings.Conversation_ContextMenuCopy), action: {
                UIPasteboard.general.string = text
            })])
            controller.dismissed = { [weak self] in
                self?.updateTextSelectionRects([], text: nil)
            }
            self.present(controller, ContextMenuControllerPresentationArguments(sourceNodeAndRect: { [weak self] in
                if let strongSelf = self {
                    return (strongSelf.scrollNode, coveringRect.insetBy(dx: -3.0, dy: -3.0))
                } else {
                    return nil
                }
            }))
            textSelectionNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.18)
        } else if let textSelectionNode = self.textSelectionNode {
            self.textSelectionNode = nil
            textSelectionNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.18, removeOnCompletion: false, completion: { [weak textSelectionNode] _ in
                textSelectionNode?.removeFromSupernode()
            })
        }
    }
    
    private func openUrl(_ url: InstantPageUrlItem) {
        guard let items = self.currentLayout?.items else {
            return
        }
        
        if let webPage = self.webPage, url.webpageId == webPage.id, let anchorRange = url.url.range(of: "#") {
            let anchor = url.url.substring(from: anchorRange.upperBound)
            if !anchor.isEmpty {
                for item in items {
                    if let item = item as? InstantPageAnchorItem, item.anchor == anchor {
                        self.scrollNode.view.setContentOffset(CGPoint(x: 0.0, y: item.frame.origin.y - self.scrollNode.view.contentInset.top), animated: true)
                        return
                    }
                }
            }
        }
        
        self.resolveUrlDisposable.set((resolveUrl(account: self.account, url: url.url) |> deliverOnMainQueue).start(next: { [weak self] result in
            if let strongSelf = self {
                switch result {
                    case let .externalUrl(url):
                        if let applicationContext = strongSelf.account.applicationContext as? TelegramApplicationContext {
                            applicationContext.applicationBindings.openUrl(url)
                        }
                    default:
                        break
                        /*case let .peer(peerId):
                         strongSelf.openPeer(peerId: peerId, navigation: .chat(textInputState: nil), fromMessageId: nil)
                         case let .botStart(peerId, payload):
                         strongSelf.openPeer(peerId: peerId, navigation: .withBotStartPayload(ChatControllerInitialBotStart(payload: payload, behavior: .interactive)), fromMessageId: nil)
                         case let .groupBotStart(peerId, payload):
                         break
                         case let .channelMessage(peerId, messageId):
                         (strongSelf.navigationController as? NavigationController)?.pushViewController(ChatController(account: strongSelf.account, peerId: peerId, messageId: messageId))*/
                }
            }
        }))
    }
    
    private func openMedia(_ media: InstantPageMedia) {
        guard let items = self.currentLayout?.items, let webPage = self.webPage else {
            return
        }
        
        if let file = media.media as? TelegramMediaFile, (file.isVoice || file.isMusic) {
            var medias: [InstantPageMedia] = []
            for item in items {
                for itemMedia in item.medias {
                    if let itemFile = itemMedia.media as? TelegramMediaFile, (itemFile.isVoice || itemFile.isMusic) {
                        medias.append(itemMedia)
                    }
                }
            }
            let player = ManagedAudioPlaylistPlayer(audioSessionManager: self.account.telegramApplicationContext.mediaManager.audioSession, overlayMediaManager: self.account.telegramApplicationContext.mediaManager.overlayMediaManager, mediaManager: self.account.telegramApplicationContext.mediaManager, account: self.account, postbox: self.account.postbox, playlist: instantPageAudioPlaylist(account: self.account, webpage: webPage, medias: medias, at: media))
            self.account.telegramApplicationContext.mediaManager.setPlaylistPlayer(player)
            player.control(.navigation(.next))
            return
        }
        
        var medias: [InstantPageMedia] = []
        for item in items {
            medias.append(contentsOf: item.medias)
        }
        
        medias = medias.filter {
            $0.media is TelegramMediaImage
        }
        
        var entries: [InstantPageGalleryEntry] = []
        for media in medias {
            entries.append(InstantPageGalleryEntry(index: Int32(media.index), media: media, caption: media.caption ?? "", location: InstantPageGalleryEntryLocation(position: Int32(entries.count), totalCount: Int32(medias.count))))
        }
        
        var centralIndex: Int?
        for i in 0 ..< entries.count {
            if entries[i].media == media {
                centralIndex = i
                break
            }
        }
        
        if let centralIndex = centralIndex {
            let controller = InstantPageGalleryController(account: self.account, entries: entries, centralIndex: centralIndex, replaceRootController: { _, _ in
            })
            self.hiddenMediaDisposable.set((controller.hiddenMedia |> deliverOnMainQueue).start(next: { [weak self] entry in
                if let strongSelf = self {
                    for (_, itemNode) in strongSelf.visibleItemsWithViews {
                        if let itemNode = itemNode as? InstantPageNode {
                            itemNode.updateHiddenMedia(media: entry?.media)
                        }
                    }
                }
            }))
            self.present(controller, InstantPageGalleryControllerPresentationArguments(transitionArguments: { [weak self] entry -> GalleryTransitionArguments? in
                if let strongSelf = self {
                    for (_, itemNode) in strongSelf.visibleItemsWithViews {
                        if let itemNode = itemNode as? InstantPageNode {
                            if let transitionNode = itemNode.transitionNode(media: entry.media) {
                                return GalleryTransitionArguments(transitionNode: transitionNode, addToTransitionSurface: { _ in
                                })
                            }
                        }
                    }
                }
                return nil
            }))
        }
    }
    
    private func presentSettings() {
        guard let settings = self.settings, let containerLayout = self.containerLayout else {
            return
        }
        if self.settingsNode == nil {
            let settingsNode = InstantPageSettingsNode(strings: self.strings, settings: settings, applySettings: { [weak self] settings in
                if let strongSelf = self {
                    strongSelf.update(settings: settings, strings: strongSelf.strings)
                    let _ = updateInstantPagePresentationSettingsInteractively(postbox: strongSelf.account.postbox, { _ in
                        return settings
                    }).start()
                }
            })
            self.addSubnode(settingsNode)
            self.settingsNode = settingsNode
            
            let settingsDimNode = ASDisplayNode()
            settingsDimNode.backgroundColor = UIColor(rgb: 0, alpha: 0.1)
            settingsDimNode.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(settingsDimTapped(_:))))
            self.insertSubnode(settingsDimNode, belowSubnode: self.navigationBar)
            self.settingsDimNode = settingsDimNode
            
            settingsDimNode.frame = CGRect(origin: CGPoint(), size: containerLayout.size)
            
            settingsNode.frame = CGRect(origin: CGPoint(), size: containerLayout.size)
            settingsNode.updateLayout(layout: containerLayout, transition: .immediate)
            settingsNode.animateIn()
            settingsDimNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
            
            let transition: ContainedViewLayoutTransition = .animated(duration: 0.3, curve: .easeInOut)
            self.navigationBar.updateDimmed(true, transition: transition)
            transition.updateAlpha(node: self.statusBar, alpha: 0.5)
        }
    }
    
    @objc func settingsDimTapped(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            if let settingsNode = self.settingsNode {
                self.settingsNode = nil
                settingsNode.animateOut(completion: { [weak settingsNode] in
                    settingsNode?.removeFromSupernode()
                })
            }
            
            if let settingsDimNode = self.settingsDimNode {
                self.settingsDimNode = nil
                settingsDimNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false, completion: { [weak settingsDimNode] _ in
                    settingsDimNode?.removeFromSupernode()
                })
            }
            
            let transition: ContainedViewLayoutTransition = .animated(duration: 0.3, curve: .easeInOut)
            self.navigationBar.updateDimmed(false, transition: transition)
            transition.updateAlpha(node: self.statusBar, alpha: 1.0)
        }
    }
}
