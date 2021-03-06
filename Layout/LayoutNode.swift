//  Copyright © 2017 Schibsted. All rights reserved.

import UIKit

/// LayoutNode represents a single node of a layout tree
/// The LayoutNode retains its view/view controller, so any references
/// from the view back to the node should be weak
public class LayoutNode: NSObject {

    /// The view managed by this node
    /// Accessing this property will instantiate the view if it doesn't already exist
    public var view: UIView {
        attempt(setUpExpressions)
        if _view == nil {
            _view = viewClass.init()
        }
        return _view!
    }

    /// The (optional) view controller managed by this node
    /// Accessing this property will instantiate the view controller if it doesn't already exist
    public var viewController: UIViewController? {
        if _class is UIViewController.Type {
            attempt(setUpExpressions)
        }
        return _viewController
    }

    /// All top-level view controllers belonging to this node or its children
    /// These should be added as child view controllers to the node's parent view controller
    /// Accessing this property will instantiate the view hierarchy if it doesn't already exist
    public var viewControllers: [UIViewController] {
        guard let viewController = viewController else {
            return children.flatMap { $0.viewControllers }
        }
        return [viewController]
    }

    /// The name of an outlet belonging to the nodes' owner that the node should bind to
    public var outlet: String? {
        return attempt { try value(forExpression: "outlet") } as? String
    }

    /// The node identifier, which can be used to refer to the node from within an expression
    public private(set) var id: String?

    /// The expressions used to initialized the node
    public private(set) var expressions: [String: String]

    /// Constants that can be referenced by expressions in the node and its children
    public internal(set) var constants: [String: Any]

    // The delegate used for handling errors
    // Normally this is the same as the owner, but it can be overridden in special cases
    private weak var _delegate: LayoutDelegate?
    weak var delegate: LayoutDelegate? {
        get {
            return _delegate ??
                (_owner as? LayoutDelegate) ??
                (viewController as? LayoutDelegate) ??
                (_view as? LayoutDelegate) ??
                parent?.delegate
        }
        set {
            _delegate = newValue
        }
    }

    /// Get the view class without side-effects of accessing view
    public var viewClass: UIView.Type { return _class as? UIView.Type ?? UIView.self }

    /// Get the view controller class without side-effects of accessing view
    public var viewControllerClass: UIViewController.Type? { return _class as? UIViewController.Type }

    // For internal use
    private(set) var _class: AnyClass
    @objc var _view: UIView?
    private(set) var _viewController: UIViewController?
    private(set) var _originalExpressions: [String: String]
    private var _usesAutoLayout = false
    var _parameters: [String: RuntimeType]
    var _macros: [String: String]
    var rootURL: URL?

    func expression(forMacro name: String) -> String? {
        attempt(completeSetup)
        return _macros[name] ?? parent?.expression(forMacro: name)
    }

    // Note: The LayoutNode lifecycle works as follows:
    // completeSetup() creates the view/controller and sets properties that depend on it
    // such as autolayout conformance, expression overrides, and observers
    // once these are set up, they won't be reset by a cleanUp(), so anything that
    // may effect them (such as adding children), must be done again

    // Note: Thrown error is always a LayoutError
    private var _setupComplete = false
    private func completeSetup() throws {
        guard !_setupComplete else { return }
        _setupComplete = true

        defer { _updateLock -= 1 }
        _updateLock += 1

        if _view == nil {
            if let controllerClass = viewControllerClass {
                _viewController = try LayoutError.wrap({
                    try controllerClass.create(with: self)
                }, for: self)
                _view = _viewController!.view
            } else {
                _view = try LayoutError.wrap({
                    try viewClass.create(with: self)
                }, for: self)
                assert(_view != nil)
            }
        }
        if let layoutBacked = (_viewController ?? _view) as? LayoutBacked {
            layoutBacked.setLayoutNode(self)
        }

        // AutoLayout support
        _usesAutoLayout = _view!.constraints.contains {
            [.top, .left, .bottom, .right, .width, .height].contains($0.firstAttribute)
        }
        _widthConstraint = _view?.widthAnchor.constraint(equalToConstant: 0)
        _widthConstraint?.priority = UILayoutPriority(rawValue: UILayoutPriority.required.rawValue - 1)
        _widthConstraint?.identifier = "LayoutWidth"
        _heightConstraint = _view?.heightAnchor.constraint(equalToConstant: 0)
        _heightConstraint?.priority = UILayoutPriority(rawValue: UILayoutPriority.required.rawValue - 1)
        _heightConstraint?.identifier = "LayoutHeight"

        _ = updateVariables() // Must be done before expressions are overridden
        setUpPositionConstraints()
        overrideExpressions()
        updateObservers()

        var index = 0
        for child in children {
            if let viewController = _view?.viewController {
                if viewController.shouldInsertChildNode(child, at: index) {
                    child.parent = self
                    viewController.didInsertChildNode(child, at: index)
                    index += 1
                } else {
                    children.remove(at: index)
                }
            } else if _view?.shouldInsertChildNode(child, at: index) == true {
                child.parent = self
                _view?.didInsertChildNode(child, at: index)
                index += 1
            } else {
                children.remove(at: index)
            }
        }
    }

    private var _observingContentSizeCategory = false
    private func _stopObservingContentSizeCategory() {
        if _observingContentSizeCategory {
            NotificationCenter.default.removeObserver(self, name: .UIContentSizeCategoryDidChange, object: nil)
        }
    }

    private var _observingFrame = false
    private func _stopObservingFrame() {
        if _observingFrame {
            removeObserver(self, forKeyPath: "_view.translatesAutoresizingMaskIntoConstraints")
            removeObserver(self, forKeyPath: "_view.frame")
            removeObserver(self, forKeyPath: "_view.bounds")
            _observingFrame = false
        }
    }

    private var _observingInsets = false
    private var _shouldObserveInsets: Bool {
        guard let viewControllerClass = viewControllerClass else {
            return false
        }
        return !(viewControllerClass is UITabBarController.Type) &&
            !(viewControllerClass is UINavigationController.Type)
    }
    private func _stopObservingInsets() {
        if #available(iOS 11.0, *), _observingInsets {
            removeObserver(self, forKeyPath: "_view.safeAreaInsets")
            _observingInsets = false
        }
    }

    private func stopObserving() {
        _stopObservingContentSizeCategory()
        _stopObservingFrame()
        _stopObservingInsets()
    }

    // Depends on presence of parent - must be called again if parent is added or removed
    private func updateObservers() {
        if _observingContentSizeCategory, parent != nil {
            _stopObservingContentSizeCategory()
        } else if !_observingContentSizeCategory, parent == nil {
            NotificationCenter.default.addObserver(self, selector: #selector(contentSizeCategoryChanged), name: .UIContentSizeCategoryDidChange, object: nil)
        }
        if !_observingFrame {
            addObserver(self, forKeyPath: "_view.translatesAutoresizingMaskIntoConstraints", options: [.new, .old], context: nil)
            addObserver(self, forKeyPath: "_view.frame", options: .new, context: nil)
            addObserver(self, forKeyPath: "_view.bounds", options: .new, context: nil)
            _observingFrame = true
        }
        if _observingInsets, !_shouldObserveInsets {
            _stopObservingInsets()
        } else if #available(iOS 11.0, *), !_observingInsets, _shouldObserveInsets {
            addObserver(self, forKeyPath: "_view.safeAreaInsets", options: .new, context: nil)
            _observingInsets = true
        }
    }

    var _anyChildDependsOnContentOffset: Bool?
    public override func observeValue(
        forKeyPath _: String?,
        of _: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context _: UnsafeMutableRawPointer?
    ) {
        guard _setupComplete, _updateLock == 0, _evaluating.isEmpty, let new = change?[.newKey] else {
            return
        }
        switch new {
        case let rect as CGRect:
            if !rect.size.isNearlyEqual(to: _previousBounds.size) {
                if root._view?.superview != nil, root._setupComplete,
                    root._updateLock == 0, root._evaluating.isEmpty {
                    root.update()
                }
            } else if _view is UIScrollView, !rect.origin.isNearlyEqual(to: _previousBounds.origin) {
                if _anyChildDependsOnContentOffset == nil {
                    _anyChildDependsOnContentOffset = anyExpressionDependsOn([
                        "contentOffset", "contentOffset.x", "contentOffset.y",
                        "bounds", "bounds.origin", "bounds.origin.x", "bounds.origin.y",
                        "bounds.x", "bounds.y",
                    ])
                }
                if _anyChildDependsOnContentOffset == true {
                    children.forEach { $0.update() }
                }
            }
        case let insets as UIEdgeInsets:
            if _view?.window != nil, !insets.isNearlyEqual(to: _previousSafeAreaInsets) {
                // If not yet mounted, safe area insets can't be valid
                update()
            }
            _previousSafeAreaInsets = insets
        case let useAutoresizing as Bool:
            if useAutoresizing != change?[.oldKey] as? Bool {
                update()
            }
        default:
            preconditionFailure()
        }
    }

    @objc private func contentSizeCategoryChanged() {
        guard _setupComplete else {
            return
        }
        cleanUp(recursive: true)
        update()
    }

    // Create the node using a UIView or UIViewController subclass
    // TODO: is there any reason not to make this public?
    init(
        class: AnyClass,
        id: String? = nil,
        state: Any = (),
        constants: [String: Any]...,
        expressions: [String: String] = [:],
        children: [LayoutNode] = []
    ) throws {
        guard `class` is UIView.Type || `class` is UIViewController.Type else {
            throw LayoutError.message("\(`class`) is not a subclass of UIView or UIViewController")
        }
        _class = `class`
        _state = try! unwrap(state)
        self.id = id
        self.constants = merge(constants)
        self.expressions = expressions
        self.children = children

        _parameters = [:]
        _macros = [:]
        _originalExpressions = expressions

        super.init()

        // Merge expressions with defaults
        let defaultExpressions = viewControllerClass?.defaultExpressions ?? viewClass.defaultExpressions
        for (key, value) in defaultExpressions {
            guard !hasExpression(key) else { continue }
            switch key {
            case "left" where hasExpression("width") && hasExpression("right"),
                 "right" where hasExpression("width") && hasExpression("left"),
                 "width" where hasExpression("left") && hasExpression("right"),
                 "top" where hasExpression("height") && hasExpression("bottom"),
                 "bottom" where hasExpression("height") && hasExpression("top"),
                 "height" where hasExpression("top") && hasExpression("bottom"):
                break // Redundant
            default:
                _originalExpressions[key] = value
                _getters[key] = nil
            }
        }
    }

    /// Create a node for managing a view controller instance
    public convenience init(
        viewController: UIViewController,
        id: String? = nil,
        outlet: String? = nil,
        state: Any = (),
        constants: [String: Any]...,
        expressions: [String: String] = [:],
        children: [LayoutNode] = []
    ) {
        assert(Thread.isMainThread)

        var expressions = expressions
        if let outlet = outlet {
            expressions["outlet"] = outlet
        }
        try! self.init(
            class: viewController.classForCoder,
            id: id,
            state: state,
            constants: merge(constants),
            expressions: expressions,
            children: children
        )

        _viewController = viewController
        _view = viewController.view
    }

    /// Create a node for managing a view instance
    public convenience init(
        view: UIView? = nil,
        id: String? = nil,
        outlet: String? = nil,
        state: Any = (),
        constants: [String: Any]...,
        expressions: [String: String] = [:],
        children: [LayoutNode] = []
    ) {
        assert(Thread.isMainThread)

        var expressions = expressions
        if let outlet = outlet {
            expressions["outlet"] = outlet
        }
        try! self.init(
            class: view?.classForCoder ?? UIView.self,
            id: id,
            state: state,
            constants: merge(constants),
            expressions: expressions,
            children: children
        )

        _view = view
    }

    deinit {
        if let layoutBacked = (_viewController ?? _view) as? LayoutBacked, layoutBacked.layoutNode == self {
            layoutBacked.setLayoutNode(nil)
        }
        stopObserving()
    }

    // MARK: Validation

    /// Test if the specified expression is valid for a given view or view controller class
    /// NOTE: only used by UIDesigner - should we deprecate this?
    public static func isValidExpressionName(
        _ name: String, for viewOrViewControllerClass: AnyClass) -> Bool {
        switch name {
        case "top", "left", "bottom", "right", "width", "height", "outlet":
            return true
        default:
            if let viewClass = viewOrViewControllerClass as? UIView.Type {
                return viewClass.cachedExpressionTypes[name]?.isAvailable == true
            } else if let viewControllerClass = viewOrViewControllerClass as? UIViewController.Type {
                return viewControllerClass.cachedExpressionTypes[name]?.isAvailable ??
                    UIView.cachedExpressionTypes[name]?.isAvailable == true
            }
            preconditionFailure("\(viewOrViewControllerClass) is not a UIView or UIViewController subclass")
        }
    }

    /// Perform pre-validation on the node and (optionally) its children
    /// Returns a set of LayoutError's, or an empty set if the node is valid
    public func validate(recursive: Bool = true) -> Set<LayoutError> {
        var errors = Set<LayoutError>()
        do {
            try setUpExpressions()
        } catch {
            errors.insert(LayoutError(error, for: self))
        }
        for name in expressions.keys {
            do {
                _ = try _getters[name]?()
            } catch {
                errors.insert(LayoutError(error, for: self))
            }
        }
        errors.formUnion(redundantExpressionErrors())
        if recursive {
            for child in children {
                errors.formUnion(child.validate())
            }
        }
        return errors
    }

    func hasExpression(_ name: String) -> Bool {
        if _originalExpressions[name] != nil {
            attempt { try setUpExpression(for: name) } // Sets expressions[name] to nil if empty
            if expressions[name] != nil {
                return true
            }
            _originalExpressions[name] = nil // Prevents false postives when overridden
        }
        return false
    }

    private func redundantExpressionErrors() -> Set<LayoutError> {
        var errors = Set<LayoutError>()
        if hasExpression("bottom"),
            !value(forSymbol: "height", dependsOn: "bottom"),
            !value(forSymbol: "top", dependsOn: "bottom") {
            errors.insert(LayoutError(SymbolError("Expression for bottom is redundant",
                                                  for: "bottom"), for: self))
        }
        if hasExpression("right"),
            !value(forSymbol: "width", dependsOn: "right"),
            !value(forSymbol: "left", dependsOn: "right") {
            errors.insert(LayoutError(SymbolError("Expression for right is redundant",
                                                  for: "right"), for: self))
        }
        return errors
    }

    // Find an the appropriate target object for a given selector
    private func target(for selector: Selector) -> LayoutDelegate? {
        var delegate = self.delegate
        var responder = delegate as? UIResponder
        while delegate != nil || responder != nil {
            if (delegate as AnyObject).responds(to: selector) {
                return delegate
            }
            responder = responder?.next ?? (responder as? UIViewController)?.parent
            delegate = responder as? LayoutDelegate
        }
        return parent?.target(for: selector)
    }

    private var _unhandledError: LayoutError?
    func throwUnhandledError() throws {
        try _unhandledError.map {
            if $0.isTransient {
                _unhandledError = nil
            }
            unbind()
            throw $0
        }
    }

    private func bubbleUnhandledError() {
        guard let error = _unhandledError else {
            return
        }
        if let parent = parent {
            if parent._unhandledError == nil ||
                (parent._unhandledError?.isTransient == true && !error.isTransient) {
                parent._unhandledError = LayoutError(error, for: parent)
                if error.isTransient {
                    _unhandledError = nil
                }
                parent.bubbleUnhandledError()
            }
            return
        }
        if let delegate = self.target(for: #selector(LayoutDelegate.layoutNode(_:didDetectError:))) {
            if error.isTransient {
                _unhandledError = nil
            }
            delegate.layoutNode?(self, didDetectError: error)
            return
        }
        if !error.isTransient {
            assertionFailure("Layout error: \(error)")
        }
    }

    // Attempt a throwing operation but catch the error and bubble it up the Layout hierarchy
    func attempt<T>(_ closure: () throws -> T) -> T? {
        do {
            return try closure()
        } catch {
            let error = LayoutError(error, for: self)
            if _unhandledError == nil || (_unhandledError?.isTransient == true && !error.isTransient) {
                _unhandledError = error
                // Don't bubble if we're in the middle of evaluating an expression
                if _evaluating.isEmpty {
                    bubbleUnhandledError()
                }
            }
            return nil
        }
    }

    // MARK: State

    private var _state: Any

    /// Update the node state and re-evaluate any expressions that are affected
    /// There is no need to call `update()` after setting the state as it is done automatically
    public func setState(_ newState: Any, animated: Bool = false) {
        var equal = true
        if let newState = newState as? [String: Any], var oldState = _state as? [String: Any] {
            for (key, value) in newState {
                guard let oldValue = oldState[key] else {
                    preconditionFailure("Cannot add new keys to state after initialization")
                }
                equal = equal && areEqual(oldValue, value)
                oldState[key] = value
            }
            _state = oldState
        } else {
            let oldState = _state
            _state = try! unwrap(newState)
            let oldType = type(of: oldState)
            assert(oldType == Void.self || oldType == type(of: _state), "Cannot change type of state after initialization")
            equal = areEqual(oldState, _state)
        }
        if !equal, updateVariables() {
            // TODO: work out which expressions are actually affected
            update(animated: animated)
        }
    }

    private var _variables = [String: Any]()
    private func updateVariables() -> Bool {
        if let members = _state as? [String: Any] {
            _variables = members
            return true
        }
        // TODO: what about nested objects?
        var equal = true
        let mirror = Mirror(reflecting: _state)
        for (name, value) in mirror.children {
            if let name = name, (equal && areEqual(_variables[name] as Any, value)) == false {
                _variables[name] = value
                equal = false
            }
        }
        return !equal
    }

    // MARK: Hierarchy

    /// The immediate child-nodes of this layout (retained)
    public private(set) var children: [LayoutNode]

    /// The parent node of this layout (unretained)
    public private(set) weak var parent: LayoutNode? {
        didSet {
            if let parent = parent, parent._setupComplete {
                parent.cleanUp(recursive: false)
            }
            if _setupComplete {
                _leftConstraint.map {
                    oldValue?._view?.removeConstraint($0)
                    _leftConstraint = nil
                }
                _topConstraint.map {
                    oldValue?._view?.removeConstraint($0)
                    _topConstraint = nil
                }
                cleanUp(recursive: true)
                // These must be called again if parent changes
                if (parent == nil) != (oldValue == nil) {
                    updateObservers()
                    overrideExpressions()
                }
                setUpPositionConstraints()
                bubbleUnhandledError()
            }
        }
    }

    /// The root node of this layout tree (unretained)
    private var _root: LayoutNode?
    public var root: LayoutNode {
        if _root == nil {
            _root = parent?.root ?? self
        }
        return _root!
    }

    /// The previous sibling of the node within its parent
    /// Returns nil if this is a root node, or is the first child of its parent
    var previous: LayoutNode? {
        if let siblings = parent?.children, let index = siblings.index(where: { $0 === self }), index > 0 {
            return siblings[index - 1]
        }
        return nil
    }

    /// The next sibling of the node within its parent
    /// Returns nil if this is a root node, or is the last child of its parent
    var next: LayoutNode? {
        if let siblings = parent?.children, let index = siblings.index(where: { $0 === self }),
            index < siblings.count - 1 {
            return siblings[index + 1]
        }
        return nil
    }

    // Find a node by id, starting with the children and then progressing to siblings and parents
    func node(withID id: String, excluding: LayoutNode? = nil) -> LayoutNode? {
        attempt(completeSetup)
        if self.id == id {
            return self
        }
        for child in children where child !== excluding {
            if let match = child.node(withID: id, excluding: self) {
                return match
            }
        }
        if parent != excluding {
            return parent?.node(withID: id, excluding: self)
        }
        return nil
    }

    /// Find all children with matching id
    public func children(withID id: String) -> [LayoutNode] {
        return children.flatMap { child -> [LayoutNode] in
            let matches = child.children(withID: id)
            return child.id == id ? [child] + matches : matches
        }
    }

    /// Perform a depth-first search for a child node with matching id
    public func childNode(withID id: String) -> LayoutNode? {
        for child in children {
            if child.id == id {
                return child
            }
            if let match = child.childNode(withID: id) {
                return match
            }
        }
        return nil
    }

    /// Appends a new child node to this node's children
    /// Note: this will not necessarily trigger an update
    public func addChild(_ child: LayoutNode) {
        insertChild(child, at: children.count)
    }

    /// Inserts a new child node at the specified index
    /// Note: this will not necessarily trigger an update
    public func insertChild(_ child: LayoutNode, at index: Int) {
        child.removeFromParent()
        children.insert(child, at: index)
        if _setupComplete {
            child.parent = self
            if let owner = _owner {
                try? child.bind(to: owner)
            }
            if let viewController = _viewController {
                viewController.didInsertChildNode(child, at: index)
            } else {
                _view?.didInsertChildNode(child, at: index)
            }
        }
    }

    /// Replaces the child node at the specified index with this one
    /// Note: this will not necessarily trigger an update
    public func replaceChild(at index: Int, with child: LayoutNode) {
        children[index].removeFromParent()
        insertChild(child, at: index)
    }

    /// Removes the node from its parent
    /// Note: this will not necessarily trigger an update in either node
    public func removeFromParent() {
        if let index = parent?.children.index(where: { $0 === self }) {
            if let viewController = parent?._viewController {
                viewController.willRemoveChildNode(self, at: index)
            } else {
                parent?._view?.willRemoveChildNode(self, at: index)
            }
            unbind()
            parent?.children.remove(at: index)
            parent = nil
            return
        }
        _view?.removeFromSuperview()
        for controller in viewControllers {
            controller.removeFromParentViewController()
        }
    }

    // Experimental - used for nested XML reference loading
    internal func update(with layout: Layout) throws {
        let newClass: AnyClass = try layout.getClass()
        let oldClass: AnyClass = _class
        guard newClass.isSubclass(of: oldClass) else {
            throw LayoutError("Cannot replace \(oldClass) with \(newClass)", for: self)
        }

        for child in children {
            child.removeFromParent()
        }

        if newClass != oldClass {
            stopObserving()

            let oldView = _view
            _view = nil

            let oldViewController = _viewController
            _viewController = nil

            _class = newClass
            viewExpressionTypes = viewClass.cachedExpressionTypes
            viewControllerClass.map {
                self.viewControllerExpressionTypes = $0.cachedExpressionTypes
            }

            if _setupComplete {

                // NOTE: this convoluted update process is needed to ensure that if the
                // class changes, the new view or controller is inserted at the correct
                // position in the hierarchy

                _setupComplete = false

                _widthConstraint.map {
                    oldView?.removeConstraint($0)
                    _widthConstraint = nil
                }
                _heightConstraint.map {
                    oldView?.removeConstraint($0)
                    _heightConstraint = nil
                }
                _leftConstraint.map {
                    oldView?.removeConstraint($0)
                    _leftConstraint = nil
                }
                _topConstraint.map {
                    oldView?.removeConstraint($0)
                    _topConstraint = nil
                }

                unmount()
                if let parent = parent, let index = parent.children.index(of: self) {
                    oldView?.removeFromSuperview()
                    oldViewController?.removeFromParentViewController()
                    parent.insertChild(self, at: index)
                } else if let superview = oldView?.superview,
                    let index = superview.subviews.index(of: oldView!) {
                    if let parentViewController = oldViewController?.parent {
                        oldViewController?.removeFromParentViewController()
                        parentViewController.addChildViewController(viewController!)
                    }
                    oldView!.removeFromSuperview()
                    superview.insertSubview(view, at: index)
                }
            }
        }

        for (name, type) in layout.parameters where _parameters[name] == nil { // TODO: should parameter shadowing be allowed?
            _parameters[name] = type
        }

        for (name, value) in layout.macros where _macros[name] == nil { // TODO: should macro shadowing be allowed?
            _macros[name] = value
        }

        for (name, expression) in layout.expressions where !hasExpression(name) {
            _originalExpressions[name] = expression
            _getters[name] = nil
        }

        if _setupComplete {
            root.cleanUp(recursive: true)
            overrideExpressions()
        }

        if layout.expressions["outlet"] != nil {
            try LayoutError.wrap({ try _owner.map { try bind(to: $0) } }, for: self)
        }

        for child in layout.children {
            addChild(try LayoutNode(layout: child))
        }
        if _setupComplete, _view?.window != nil || _owner != nil {
            update()
        }
    }

    // MARK: expressions

    // Depends on presence of parent - must be called again if parent is added or removed
    private func overrideExpressions() {
        assert(_setupComplete && !_expressionsSetUp && _view != nil)
        expressions = _originalExpressions

        // layout props
        if !hasExpression("width") {
            _getters["width"] = nil
            if hasExpression("left"), hasExpression("right") {
                expressions["width"] = "right - left"
            } else if !(_view is UIScrollView), _view is UIImageView || _usesAutoLayout ||
                _view?.intrinsicContentSize.width != UIViewNoIntrinsicMetric {
                expressions["width"] = "100% == 0 ? auto : min(auto, 100%)"
            } else if parent != nil {
                expressions["width"] = "100%"
            }
        }
        if !hasExpression("left"), hasExpression("right") {
            _getters["left"] = nil
            expressions["left"] = "right - width"
        }
        if !hasExpression("height") {
            _getters["height"] = nil
            if hasExpression("top"), hasExpression("bottom") {
                expressions["height"] = "bottom - top"
            } else if !(_view is UIScrollView), _view is UIImageView || _usesAutoLayout ||
                _view?.intrinsicContentSize.height != UIViewNoIntrinsicMetric {
                expressions["height"] = "auto"
            } else if parent != nil {
                expressions["height"] = "100%"
            }
        }
        if !hasExpression("top"), hasExpression("bottom") {
            _getters["top"] = nil
            expressions["top"] = "bottom - height"
        }
    }

    private func clearCachedValues() {
        for fn in _valueClearers { fn() }
    }

    private func cleanUp(recursive: Bool) {
        assert(!_settingUpExpressions)
        if let error = _unhandledError, error.isTransient {
            _unhandledError = nil
        }
        _root = nil
        _widthDependsOnParent = nil
        _heightDependsOnParent = nil
        _anyChildDependsOnContentOffset = nil
        if _expressionsSetUp {
            _expressionsSetUp = false
            _updateExpressionValues = { _ in }
        }
        if !_getters.isEmpty {
            _getters.removeAll()
            _layoutExpressions.removeAll()
            _viewControllerExpressions.removeAll()
            _viewExpressions.removeAll()
            _valueClearers.removeAll()
            _valueHasChanged.removeAll()
        }
        if recursive {
            for child in children {
                child.cleanUp(recursive: true)
            }
        }
    }

    private typealias Getter = () throws -> Any

    private var _evaluating = [String]()
    private var _getters = [String: Getter]()
    private var _layoutExpressions = [String: LayoutExpression]()
    private var _viewControllerExpressions = [String: LayoutExpression]()
    private var _sortedViewControllerGetters = [Getter]()
    private var _viewExpressions = [String: LayoutExpression]()
    private var _sortedViewGetters = [Getter]()
    private var _valueClearers = [() -> Void]()
    private var _valueHasChanged = [String: () -> Bool]()

    // Note: thrown error is always a SymbolError
    private var _updateExpressionValues: (_ animated: Bool) throws -> Void = { _ in }

    private lazy var constructorArgumentTypes: [String: RuntimeType] =
        self.viewControllerClass?.parameterTypes ?? self.viewClass.parameterTypes

    // Returns all expressions that can be set on the node
    // Used for generating error suggestions
    var availableExpressions: [String] {
        var expressions = Array(layoutSymbols)
        expressions += ["outlet", "id", "xml", "template"]
        expressions += _parameters.keys
        if let controllerClass = viewControllerClass {
            expressions +=
                Array(controllerClass.expressionTypes.flatMap { $0.value.isAvailable ? $0.key : nil }) +
                Array(UIView.expressionTypes.flatMap { $0.value.isAvailable ? $0.key : nil })
        } else {
            expressions += Array(viewClass.expressionTypes.flatMap { $0.value.isAvailable ? $0.key : nil })
        }
        return expressions
    }

    private func keys(in values: [String: Any], matching type: RuntimeType) -> [String] {
        var matches = [String]()
        for (key, value) in values {
            if type.matches(value) {
                matches.append(key)
            } else if let values = value as? [String: Any] {
                matches += keys(in: values, matching: type).map { "\(key).\($0)" }
            }
        }
        return matches
    }

    // Returns all symbols that can be referenced in an expression
    func availableSymbols(forExpression name: String) -> [String] {
        var symbols = [String]()
        var type: RuntimeType
        switch name {
        case "left", "right", "top", "bottom":
            type = .cgFloat
        case "width", "height":
            type = .cgFloat
            symbols.append("auto")
        case "outlet", "id", "xml", "template":
            type = .string
        default:
            func validKeys(in types: [String: RuntimeType]) -> [String] {
                return types.flatMap { $0.key != name && $0.value == type ? $0.key : nil }
            }
            if let controllerClass = viewControllerClass {
                type = controllerClass.expressionTypes[name] ?? UIView.expressionTypes[name] ?? .any
                symbols += validKeys(in: controllerClass.expressionTypes)
                symbols += validKeys(in: UIView.expressionTypes)
            } else {
                type = viewClass.expressionTypes[name] ?? .any
                symbols += validKeys(in: viewClass.expressionTypes)
            }
        }
        symbols += type.values.keys
        // TODO: basing the search on type is not especially effective because
        // you can use symbols of other types inside an expression, but if we
        // don't filter it somehow then there will be too many possible results
        var node: LayoutNode? = self
        while let _node = node {
            symbols += keys(in: _node.constants, matching: type)
            for (key, value) in _node._variables where type.matches(value) {
                symbols.append(key)
            }
            if _node != self {
                for (key, _type) in _node._parameters where type == _type {
                    symbols.append(key)
                }
                // TODO: macros?
            }
            node = _node.parent
        }
        return symbols
    }

    // Note: thrown error is always a SymbolError
    private func setUpExpression(for symbol: String) throws {
        guard _getters[symbol] == nil, let string = expressions[symbol], !_evaluating.contains(symbol) else {
            return
        }

        enum ExpressionType {
            case viewController
            case view
            case layout
        }

        var expression: LayoutExpression!
        var expressionType = ExpressionType.layout
        do {
            _evaluating.append(symbol)
            defer { _evaluating.removeLast() }
            switch symbol {
            case "left", "right":
                expression = LayoutExpression(xExpression: string, for: self)
            case "top", "bottom":
                expression = LayoutExpression(yExpression: string, for: self)
            case "width":
                expression = LayoutExpression(widthExpression: string, for: self)
            case "height":
                expression = LayoutExpression(heightExpression: string, for: self)
            case "outlet":
                expression = LayoutExpression(outletExpression: string, for: self)
                if let expression = expression, !expression.isConstant {
                    throw SymbolError("Expression for `\(symbol)` must be a constant or literal value", for: symbol)
                }
            default:
                let type: RuntimeType
                if let viewControllerType = viewControllerExpressionTypes[symbol] {
                    if viewControllerType.isAvailable {
                        type = viewControllerType
                        expressionType = .viewController
                    } else {
                        type = constructorArgumentTypes[symbol] ?? viewControllerType
                    }
                } else if let viewType = viewExpressionTypes[symbol] {
                    if viewType.isAvailable {
                        type = viewType
                        expressionType = .view
                    } else {
                        type = constructorArgumentTypes[symbol] ?? viewType
                    }
                } else if let parameterType = _parameters[symbol] {
                    // TODO: check for parameter type / view type conflicts?
                    type = parameterType
                } else if let constructorType = constructorArgumentTypes[symbol] {
                    // TODO: check for constructor type / view type conflicts?
                    type = constructorType
                } else {
                    if let parts = try? parseStringExpression(string), parts.count == 1 {
                        switch parts[0] {
                        case .comment:
                            return
                        case let .expression(parsedExpression) where
                            parsedExpression.comment != nil && parsedExpression.isEmpty:
                            return
                        default:
                            break
                        }
                    }
                    if let viewControllerClass = self.viewControllerClass,
                        let viewController = try? viewControllerClass.create(with: self),
                        let _ = try? viewController.value(forSymbol: symbol) {
                        throw SymbolError(fatal: "\(_class).\(symbol) is private or read-only", for: symbol)
                    }
                    if let view = try? viewClass.create(with: self),
                        let _ = try? view.value(forSymbol: symbol) {
                        throw SymbolError(fatal: "\(_class).\(symbol) is private or read-only", for: symbol)
                    }
                    throw SymbolError("Unknown property `\(symbol)` of \(_class)", for: symbol)
                }
                switch type.availability {
                case .available:
                    break
                case let .unavailable(reason):
                    throw SymbolError(fatal: "\(_class).\(symbol) is not available\(reason.map { ". \($0)" } ?? "")", for: symbol)
                }
                if case let .any(kind) = type.type, kind is CGFloat.Type {
                    switch symbol {
                    case "contentSize.width":
                        expression = LayoutExpression(contentWidthExpression: string, for: self)
                    case "contentSize.height":
                        expression = LayoutExpression(contentHeightExpression: string, for: self)
                    default:
                        // Allow use of % in any vertical/horizontal property expression
                        let parts = symbol.components(separatedBy: ".")
                        if ["left", "right", "x", "width"].contains(parts.last!) {
                            expression = LayoutExpression(xExpression: string, for: self)
                        } else if ["top", "bottom", "y", "height"].contains(parts.last!) {
                            expression = LayoutExpression(yExpression: string, for: self)
                        } else {
                            expression = LayoutExpression(expression: string, type: type, for: self)
                        }
                    }
                } else {
                    expression = LayoutExpression(expression: string, type: type, for: self)
                }
            }
        }
        guard expression != nil else {
            expressions[symbol] = nil
            return // Expression was empty
        }

        // Store getter
        if expression.isConstant {
            _valueHasChanged[symbol] = { false }
        } else {
            var previousValue: Any?
            var cachedValue: Any?
            _valueClearers.append {
                previousValue = cachedValue
                cachedValue = nil
            }
            _valueHasChanged[symbol] = { [unowned self] in
                guard let previousValue = previousValue, let cachedValue = cachedValue else {
                    return true
                }
                return !areEqual(previousValue, cachedValue)
            }
            let evaluate: () throws -> Any = expression.evaluate
            let symbols = expression.symbols
            expression = LayoutExpression(
                evaluate: { [unowned self] in
                    if let value = cachedValue {
                        return value
                    }
                    guard !self._evaluating.contains(symbol) else {
                        // If an expression directly references itself it may be shadowing
                        // a constant or variable, so check for that first before throwing
                        if self._evaluating.last == symbol {
                            if let value = try self.value(forVariableOrConstantOrParentParameter: symbol) {
                                return value
                            }
                            if let macro = self.expression(forMacro: symbol) {
                                // TODO: allow this
                                throw SymbolError("Expression for `\(symbol)` references a macro of the same name (which is not currently supported)", for: symbol)
                            }
                        }
                        // TODO: allow expression to reference its previous value instead of treating this as an error
                        throw SymbolError("Expression for `\(symbol)` references a nonexistent symbol of the same name (expressions cannot reference themselves)", for: symbol)
                    }
                    self._evaluating.append(symbol)
                    defer {
                        assert(self._evaluating.last == symbol)
                        self._evaluating.removeLast()
                    }
                    let value = try SymbolError.wrap(evaluate, for: symbol)
                    cachedValue = value
                    return value
                },
                symbols: expression.symbols
            )
        }
        _getters[symbol] = expression.evaluate

        // Store expression
        switch expressionType {
        case .viewController:
            _viewControllerExpressions[symbol] = expression
        case .view:
            _viewExpressions[symbol] = expression
        case .layout:
            _layoutExpressions[symbol] = expression
        }
    }

    private func superExpressions(for key: String) -> [String] {
        var keys = [String]()
        var key = key
        while let range = key.range(of: ".", options: .backwards) {
            key = String(key[key.startIndex ..< range.lowerBound])
            if expressions[key] != nil { // TODO: check if constant
                keys.append(key)
            }
        }
        return keys
    }

    // Note: thrown error is always a LayoutError
    private var _settingUpExpressions = false
    private var _expressionsSetUp = false
    private func setUpExpressions() throws {
        try completeSetup()
        guard !_expressionsSetUp, !_settingUpExpressions else { return }
        _settingUpExpressions = true
        defer {
            _settingUpExpressions = false
            _expressionsSetUp = true
        }
        for symbol in expressions.keys {
            try LayoutError.wrap({ try setUpExpression(for: symbol) }, for: self)
        }

        var blocks = [(Bool) throws -> Void]()
        try LayoutError.wrap({
            for key in _viewControllerExpressions.keys.sorted() {
                let expression = _viewControllerExpressions[key]!
                let keys = [key] + superExpressions(for: key)
                if !keys.contains(where: { !_viewControllerExpressions[$0]!.isConstant }) {
                    try _viewController?.setValue(expression.evaluate(), forExpression: key)
                    continue
                }
                blocks.append { [unowned self] animated in
                    let value = try expression.evaluate()
                    if keys.contains(where: { self._valueHasChanged[$0]!() }) {
                        if animated {
                            try self._viewController?.setAnimatedValue(value, forExpression: key)
                        } else {
                            try self._viewController?.setValue(value, forExpression: key)
                        }
                    }
                }
            }
            for key in _viewExpressions.keys.sorted() {
                let expression = _viewExpressions[key]!
                let keys = [key] + superExpressions(for: key)
                if !keys.contains(where: { !_viewExpressions[$0]!.isConstant }) {
                    try _view?.setValue(expression.evaluate(), forExpression: key)
                    continue
                }
                blocks.append { [unowned self] animated in
                    let value = try expression.evaluate()
                    if keys.contains(where: { self._valueHasChanged[$0]!() }) {
                        if animated {
                            try self._view?.setAnimatedValue(value, forExpression: key)
                        } else {
                            try self._view?.setValue(value, forExpression: key)
                        }
                    }
                }
            }
        }, for: self)
        _updateExpressionValues = { [unowned self] animated in
            for block in blocks {
                try block(animated)
            }
            try self.bindActions()
        }

        #if arch(i386) || arch(x86_64)

            // Validate expressions
            for error in redundantExpressionErrors() {
                throw error
            }

        #endif
    }

    // MARK: symbols

    private func localizedString(forKey key: String) throws -> String {
        guard let delegate = self.target(for: #selector(LayoutDelegate.layoutNode(_:localizedStringForKey:))) else {
            throw SymbolError("No layoutNode(_:localizedStringForKey:) implementation found. Unable to look up localized string", for: key)
        }
        guard let string = delegate.layoutNode?(self, localizedStringForKey: key) else {
            throw SymbolError("Missing localized string", for: key)
        }
        return string
    }

    // Note: thrown error is always a SymbolError
    private func value(forParameter name: String) throws -> Any? {
        guard _parameters[name] != nil else {
            return nil
        }
        guard expressions[name] != nil, let getter = _getters[name] else {
            throw SymbolError("Missing value for parameter \(name)", for: name)
        }
        return try getter()
    }

    private func value(forKeyPath keyPath: String, in dictionary: [String: Any]) throws -> Any? {
        if let value = dictionary[keyPath] {
            return value
        }
        guard let range = keyPath.range(of: ".") else {
            return nil
        }
        let key: String = String(keyPath[keyPath.startIndex ..< range.lowerBound])
        // TODO: if not a dictionary, should we use a mirror?
        if let dictionary = dictionary[key] as? [String: Any] {
            let subKeyPath: String = String(keyPath[range.upperBound ..< keyPath.endIndex])
            guard let value = try value(forKeyPath: subKeyPath, in: dictionary) else {
                throw SymbolError("Unknown property `\(subKeyPath)` in `\(key)`", for: keyPath)
            }
            return value
        }
        return nil
    }

    // Used by LayoutExpression
    func constantValue(forSymbol symbol: String) throws -> Any? {
        if symbolIsConstant(symbol) {
            guard !_evaluating.contains(symbol) else {
                // If an expression directly references itself it may be shadowing
                // a constant or variable, so check for that first before throwing
                if _evaluating.last == symbol {
                    if let value = try value(forVariableOrConstantOrParentParameter: symbol) {
                        return value
                    }
                    if expression(forMacro: symbol) != nil {
                        // TODO: allow this
                        throw SymbolError("Expression for `\(symbol)` references a macro of the same name (which is not currently supported)", for: symbol)
                    }
                }
                // TODO: allow expression to reference its previous value instead of treating this as an error
                throw SymbolError("Expression for `\(symbol)` references a nonexistent symbol of the same name (expressions cannot reference themselves)", for: symbol)
            }
            return try value(forSymbol: symbol)
        }

        // TODO: should we check the delegate as well?
        return nil
    }

    private func expressionIsConstant(_ name: String) -> Bool {
        assert(hasExpression(name))
        attempt { try setUpExpression(for: name) }
        if let expression = _layoutExpressions[name] ??
            _viewControllerExpressions[name] ?? _viewExpressions[name] {
            return expression.isConstant
        }
        return true
    }

    // Returns true if symbol is a constant, false if it's a variable, otherwise nil
    private func valueIsConstant(_ symbol: String) -> Bool? {
        attempt(completeSetup)
        do {
            if try value(forKeyPath: symbol, in: _variables) != nil {
                return false
            }
            if try value(forKeyPath: symbol, in: constants) != nil {
                return true
            }
            if let parent = parent {
                if parent._parameters[symbol] != nil {
                    return parent.expressionIsConstant(symbol)
                }
                return parent.valueIsConstant(symbol)
            }
            return nil
        } catch {
            return false
        }
    }

    private func symbolIsConstant(_ symbol: String) -> Bool {
        if hasExpression(symbol), !_evaluating.contains(symbol) {
            return expressionIsConstant(symbol)
        }
        if let result = valueIsConstant(symbol) {
            return result
        }
        assert(_setupComplete)
        if let range = symbol.range(of: ".") {
            let tail: String = String(symbol[range.upperBound ..< symbol.endIndex])
            switch symbol[symbol.startIndex ..< range.lowerBound] {
            case "parent":
                if let parent = parent {
                    return parent.symbolIsConstant(tail)
                }
            case "previous", "next":
                return false // TODO: if previous/next isHidden is constant, we could still get a constant value here
            case "strings":
                return true // Localizable strings are always constant
            case let head where head.hasPrefix("#"):
                let id = String(head.dropFirst())
                if let node = self.node(withID: id) {
                    return node.symbolIsConstant(tail)
                }
            default:
                return false
            }
        }
        return false
    }

    // Doesn't look up params defined directly on the callee, only its parents
    private func value(forVariableOrConstantOrParentParameter name: String) throws -> Any? {
        assert(_setupComplete)
        return try value(forKeyPath: name, in: _variables) ??
            value(forKeyPath: name, in: constants) ??
            parent?.value(forParameterOrVariableOrConstant: name) ??
            _delegate?.value?(forParameterOrVariableOrConstant: name)
    }

    func value(forParameterOrVariableOrConstant name: String) throws -> Any? {
        return try value(forParameter: name) ?? value(forVariableOrConstantOrParentParameter: name)
    }

    public lazy var viewExpressionTypes: [String: RuntimeType] = {
        self.viewClass.cachedExpressionTypes
    }()

    public lazy var viewControllerExpressionTypes: [String: RuntimeType] = {
        self.viewControllerClass.map { $0.cachedExpressionTypes } ?? [:]
    }()

    private func value(forSymbol name: String, dependsOn symbol: String) -> Bool {
        var checking = [String]()
        func _value(forSymbol name: String, dependsOn symbol: String) -> Bool {
            if checking.contains(name) {
                return true
            }
            if let expression = _layoutExpressions[name] ?? _viewControllerExpressions[name] ??
                _viewExpressions[name], !expression.isConstant {
                checking.append(name)
                defer { checking.removeLast() }
                for name in expression.symbols where
                    name == symbol || _value(forSymbol: name, dependsOn: symbol) {
                    return true
                }
            }
            return false
        }
        return _value(forSymbol: name, dependsOn: symbol)
    }

    private func anyExpressionDependsOn(_ symbols: [String]) -> Bool {
        for name in expressions.keys {
            if let expression = _layoutExpressions[name] ??
                _viewControllerExpressions[name] ?? _viewExpressions[name],
                symbols.contains(where: { expression.symbols.contains($0) }) {
                return true
            }
        }
        let symbols = symbols.flatMap { symbol -> [String] in
            if symbol.hasPrefix("#") {
                return []
            }
            if let id = self.id {
                return ["#\(id).\(symbol)", "parent.\(symbol)"]
            }
            return ["parent.\(symbol)"]
        }
        return children.contains(where: { $0.anyExpressionDependsOn(symbols) })
    }

    // Used by LayoutExpression and for unit tests
    // Note: thrown error is always a SymbolError
    func doubleValue(forSymbol symbol: String) throws -> Double {
        let anyValue = try value(forSymbol: symbol)
        if let doubleValue = anyValue as? Double {
            return doubleValue
        }
        if let cgFloatValue = anyValue as? CGFloat {
            return Double(cgFloatValue)
        }
        if let numberValue = anyValue as? NSNumber {
            return Double(truncating: numberValue)
        }
        throw SymbolError("\(symbol) is not a number", for: symbol)
    }

    // Note: thrown error is always a SymbolError
    private func cgFloatValue(forSymbol symbol: String) throws -> CGFloat {
        let anyValue = try value(forSymbol: symbol)
        if let cgFloatValue = anyValue as? CGFloat {
            return cgFloatValue
        }
        if let doubleValue = anyValue as? Double {
            return CGFloat(doubleValue)
        }
        if let numberValue = anyValue as? NSNumber {
            return CGFloat(truncating: numberValue)
        }
        throw SymbolError("\(symbol) is not a number", for: symbol)
    }

    /// Useful for custom constructors, and other native extensions
    /// Returns nil if the expression doesn't exist
    /// Note: thrown error is always a LayoutError
    public func value(forExpression name: String) throws -> Any? {
        try setUpExpression(for: name)
        if let getter = _getters[name] {
            return try LayoutError.wrap(getter, for: self)
        }
        return nil
    }

    // Used by LayoutExpression and for unit tests
    // Note: thrown error is always a SymbolError
    func value(forSymbol symbol: String) throws -> Any {
        if let getter = _getters[symbol] {
            return try getter()
        }
        attempt(completeSetup) // Using attempt to avoid throwing LayoutError
        try setUpExpression(for: symbol) // Try again now that expressions are set up
        if let getter = _getters[symbol] {
            return try getter()
        }
        let getter: Getter
        switch symbol {
        case "left":
            getter = { [unowned self] in
                self._view?.frame.minX ?? 0
            }
        case "width":
            getter = { [unowned self] in
                self._view?.frame.width ?? 0
            }
        case "right":
            getter = { [unowned self] in
                try SymbolError.wrap({
                    try self.cgFloatValue(forSymbol: "left") + self.cgFloatValue(forSymbol: "width")
                }, for: symbol)
            }
        case "top":
            getter = { [unowned self] in
                self._view?.frame.minY ?? 0
            }
        case "height":
            getter = { [unowned self] in
                self._view?.frame.height ?? 0
            }
        case "bottom":
            getter = { [unowned self] in
                try SymbolError.wrap({
                    try self.cgFloatValue(forSymbol: "top") + self.cgFloatValue(forSymbol: "height")
                }, for: symbol)
            }
        case "containerSize.width":
            getter = { [unowned self] in
                if let view = self._view {
                    switch view {
                    case let view as UITableViewCell:
                        return view.contentView.frame.width
                    case let view as UITableViewHeaderFooterView:
                        return view.contentView.frame.width
                    default:
                        break
                    }
                }
                if self._evaluating.contains("width") {
                    return 0
                }
                return try SymbolError.wrap({
                    let contentInset = try self.computeContentInset()
                    return try self.cgFloatValue(forSymbol: "width") -
                        contentInset.left - contentInset.right
                }, for: symbol)
            }
        case "containerSize.height":
            getter = { [unowned self] in
                if let view = self._view {
                    switch view {
                    case let view as UITableViewCell:
                        return view.contentView.frame.height
                    case let view as UITableViewHeaderFooterView:
                        return view.contentView.frame.height
                    default:
                        break
                    }
                }
                if self._evaluating.contains("height") {
                    return 0
                }
                return try SymbolError.wrap({
                    let contentInset = try self.computeContentInset()
                    return try self.cgFloatValue(forSymbol: "height") -
                        contentInset.top - contentInset.bottom
                }, for: symbol)
            }
        case "inferredSize.width":
            getter = { [unowned self] in
                try self.inferSize().width
            }
        case "inferredSize.height":
            getter = { [unowned self] in
                try self.inferSize().height
            }
        case "contentSize":
            getter = { [unowned self] in
                try self.inferContentSize()
            }
        case "inferredContentSize.width", "contentSize.width":
            getter = { [unowned self] in
                try self.inferContentSize().width
            }
        case "inferredContentSize.height", "contentSize.height":
            getter = { [unowned self] in
                try self.inferContentSize().height
            }
        default:
            func getterFor(_ symbol: String) -> Getter {
                let fallback: Getter
                if viewControllerClass != nil, viewControllerExpressionTypes[symbol] != nil {
                    fallback = { [unowned self] in
                        guard let viewController = self._viewController else {
                            throw SymbolError("Undefined symbol `\(symbol)`", for: symbol)
                        }
                        return try viewController.value(forSymbol: symbol)
                    }
                } else if viewControllerClass != nil, viewExpressionTypes[symbol] == nil {
                    fallback = { [unowned self] in
                        if let viewController = self._viewController,
                            let value = try? viewController.value(forSymbol: symbol) { // TODO: find a non-throwing solution for this
                            return value
                        }
                        guard let view = self._view else {
                            throw SymbolError("Undefined symbol `\(symbol)`", for: symbol)
                        }
                        return try view.value(forSymbol: symbol)
                    }
                } else {
                    fallback = { [unowned self] in
                        guard let view = self._view else {
                            throw SymbolError("Undefined symbol `\(symbol)`", for: symbol)
                        }
                        return try view.value(forSymbol: symbol)
                    }
                }
                return { [unowned self] in
                    try self.value(forParameterOrVariableOrConstant: symbol) ?? fallback()
                }
            }
            if let range = symbol.range(of: ".") {
                let tail: String = String(symbol[range.upperBound ..< symbol.endIndex])
                switch symbol[symbol.startIndex ..< range.lowerBound] {
                case "parent":
                    if parent != nil {
                        getter = { [unowned self] in
                            try self.parent?.value(forSymbol: tail) as Any
                        }
                    } else {
                        switch tail {
                        case "width", "containerSize.width":
                            getter = { [unowned self] in
                                self._view?.superview?.bounds.width ?? 0
                            }
                        case "height", "containerSize.height":
                            getter = { [unowned self] in
                                self._view?.superview?.bounds.height ?? 0
                            }
                        default:
                            getter = {
                                throw SymbolError("Undefined symbol `\(tail)`", for: symbol)
                            }
                        }
                    }
                case "previous" where layoutSymbols.contains(tail):
                    getter = { [unowned self] in
                        var previous = self.previous
                        while previous?.isHidden == true {
                            previous = previous?.previous
                        }
                        return try previous?.value(forSymbol: tail) ?? 0
                    }
                case "previous":
                    getter = { [unowned self] in
                        try self.previous?.value(forSymbol: tail) as Any
                    }
                case "next" where layoutSymbols.contains(tail):
                    getter = { [unowned self] in
                        var next = self.next
                        while next?.isHidden == true {
                            next = next?.next
                        }
                        return try next?.value(forSymbol: tail) ?? 0
                    }
                case "next":
                    getter = { [unowned self] in
                        try self.next?.value(forSymbol: tail) as Any
                    }
                case "strings":
                    getter = { [unowned self] in
                        try self.value(forParameterOrVariableOrConstant: symbol) ?? self.localizedString(forKey: tail)
                    }
                case let head where head.hasPrefix("#"):
                    let id = String(head.dropFirst())
                    if let node = self.node(withID: id) {
                        getter = { [unowned node] in
                            try node.value(forSymbol: tail) as Any
                        }
                    } else {
                        getter = {
                            throw SymbolError("Could not find node with id `\(id)`", for: symbol)
                        }
                    }
                default:
                    getter = getterFor(symbol)
                }
            } else {
                getter = getterFor(symbol)
            }
        }
        _getters[symbol] = getter
        return try getter()
    }

    // MARK: layout

    /// Is the layout's view hidden?
    public var isHidden: Bool {
        return view.isHidden
    }

    private var _previousSafeAreaInsets: UIEdgeInsets = .zero
    private var _previousBounds: CGRect = .zero

    /// The anticipated frame for the view, based on the current state
    // TODO: should this be public?
    public var frame: CGRect {
        return attempt {
            CGRect(
                x: try cgFloatValue(forSymbol: "left"),
                y: try cgFloatValue(forSymbol: "top"),
                width: _evaluating.contains("width") ? 0 : try cgFloatValue(forSymbol: "width"),
                height: _evaluating.contains("height") ? 0 : try cgFloatValue(forSymbol: "height")
            )
        } ?? .zero
    }

    private var _widthDependsOnParent: Bool?
    private var widthDependsOnParent: Bool {
        if let result = _widthDependsOnParent {
            return result
        }
        assert(_setupComplete)
        if value(forSymbol: "width", dependsOn: "parent.width") ||
            value(forSymbol: "width", dependsOn: "parent.containerSize.width") {
            _widthDependsOnParent = true
            return true
        }
        if value(forSymbol: "width", dependsOn: "inferredSize.width"),
            !hasExpression("contentSize"), !hasExpression("contentSize.width"),
            !_usesAutoLayout, _view?.intrinsicContentSize.width == UIViewNoIntrinsicMetric, children.isEmpty {
            _widthDependsOnParent = true
            return true
        }
        _widthDependsOnParent = false
        return false
    }

    private var _heightDependsOnParent: Bool?
    private var heightDependsOnParent: Bool {
        if let result = _heightDependsOnParent {
            return result
        }
        assert(_setupComplete)
        if value(forSymbol: "height", dependsOn: "parent.height") ||
            value(forSymbol: "height", dependsOn: "parent.containerSize.height") {
            _heightDependsOnParent = true
            return true
        }
        if value(forSymbol: "height", dependsOn: "inferredSize.height"),
            !hasExpression("contentSize"), !hasExpression("contentSize.height"),
            !_usesAutoLayout, _view?.intrinsicContentSize.height == UIViewNoIntrinsicMetric, children.isEmpty {
            _heightDependsOnParent = true
            return true
        }
        _heightDependsOnParent = false
        return false
    }

    private func inferContentSize() throws -> CGSize {
        // Check for explicit size
        // TODO: find a less hacky way to do this
        if hasExpression("contentSize"), !_evaluating.contains("contentSize") {
            var size = try value(forSymbol: "contentSize") as! CGSize
            if hasExpression("contentSize.width"), !_evaluating.contains("contentSize.width") {
                size.width = try cgFloatValue(forSymbol: "contentSize.width")
            }
            if hasExpression("contentSize.height"), !_evaluating.contains("contentSize.height") {
                size.height = try cgFloatValue(forSymbol: "contentSize.height")
            }
            return size
        } else if hasExpression("contentSize.width"), !_evaluating.contains("contentSize.width"),
            hasExpression("contentSize.height"), !_evaluating.contains("contentSize.height") {
            return CGSize(
                width: try cgFloatValue(forSymbol: "contentSize.width"),
                height: try cgFloatValue(forSymbol: "contentSize.height")
            )
        }
        // TODO: remove special cases
        if _view is UIStackView {
            let isVertical = try value(forSymbol: "axis") as! UILayoutConstraintAxis == .vertical
            let spacing = try cgFloatValue(forSymbol: "spacing")
            var size = CGSize.zero
            let children = self.children.filter { !$0.isHidden }
            if !children.isEmpty {
                for child in children {
                    var childSize = CGSize.zero
                    if !child._evaluating.contains("width") {
                        childSize.width = try child.cgFloatValue(forSymbol: "width")
                    }
                    if !child._evaluating.contains("height") {
                        childSize.height = try child.cgFloatValue(forSymbol: "height")
                    }
                    if isVertical {
                        size.width = max(size.width, childSize.width)
                        size.height += childSize.height + spacing
                    } else {
                        size.width += childSize.width + spacing
                        size.height = max(size.height, childSize.height)
                    }
                }
                if isVertical {
                    size.height -= spacing
                } else {
                    size.width -= spacing
                }
            } else {
                if _view?.translatesAutoresizingMaskIntoConstraints == false {
                    if let width = try computeExplicitWidth(), width != 0 {
                        _widthConstraint?.constant = width
                        _widthConstraint?.isActive = true
                    } else {
                        _widthConstraint?.isActive = false
                    }
                    if let height = try computeExplicitHeight(), height != 0 {
                        _heightConstraint?.constant = height
                        _heightConstraint?.isActive = true
                    } else {
                        _heightConstraint?.isActive = false
                    }
                }
                size = _view?.systemLayoutSizeFitting(.zero) ?? .zero
            }
            return size
        }
        // Try best fit for subviews
        var size = CGSize.zero
        if let _view = _view as? UITableViewCell {
            _view.layoutIfNeeded()
            _view.textLabel?.sizeToFit()
            _view.detailTextLabel?.sizeToFit()
            switch try value(forSymbol: "style") as? UITableViewCellStyle ?? .default {
            case .default, .subtitle:
                size.height = (_view.textLabel?.frame.height ?? 0) + (_view.detailTextLabel?.frame.height ?? 0)
            case .value1, .value2:
                size.height = max(_view.textLabel?.frame.height ?? 0, _view.detailTextLabel?.frame.height ?? 0)
            }
        }
        for child in children where !child.isHidden {
            if !child.widthDependsOnParent {
                var left: CGFloat = 0
                if !child.value(forSymbol: "left", dependsOn: "parent.width") {
                    left = try child.cgFloatValue(forSymbol: "left")
                }
                size.width = try max(size.width, left + child.cgFloatValue(forSymbol: "width"))
            }
            if !child.heightDependsOnParent {
                var top: CGFloat = 0
                if !child.value(forSymbol: "top", dependsOn: "parent.height") {
                    top = try child.cgFloatValue(forSymbol: "top")
                }
                size.height = try max(size.height, top + child.cgFloatValue(forSymbol: "height"))
            }
        }
        // If zero, fill superview
        let contentInset = try computeContentInset()
        if size.width <= 0, let width = _view?.superview?.bounds.width {
            size.width = width - contentInset.left - contentInset.right
        }
        if size.height <= 0, let height = _view?.superview?.bounds.height {
            size.height = height - contentInset.top - contentInset.bottom
        }
        // Check for explicit width / height
        if hasExpression("contentSize.width"), !_evaluating.contains("contentSize.width") {
            size.width = try cgFloatValue(forSymbol: "contentSize.width")
        } else if hasExpression("contentSize.height"), !_evaluating.contains("contentSize.height") {
            size.height = try cgFloatValue(forSymbol: "contentSize.height")
        }
        return size
    }

    private func computeContentInset() throws -> UIEdgeInsets {
        guard viewClass is UIScrollView.Type else {
            return .zero
        }
        var contentInset = try value(forSymbol: "contentInset") as! UIEdgeInsets
        if hasExpression("contentInset.top"), !_evaluating.contains("contentInset.top") {
            contentInset.top = try cgFloatValue(forSymbol: "contentInset.top")
        }
        if hasExpression("contentInset.left"), !_evaluating.contains("contentInset.left") {
            contentInset.left = try cgFloatValue(forSymbol: "contentInset.left")
        }
        if hasExpression("contentInset.bottom"), !_evaluating.contains("contentInset.bottom") {
            contentInset.bottom = try cgFloatValue(forSymbol: "contentInset.bottom")
        }
        if hasExpression("contentInset.right"), !_evaluating.contains("contentInset.right") {
            contentInset.right = try cgFloatValue(forSymbol: "contentInset.right")
        }
        if #available(iOS 11.0, *) {
            let contentInsetAdjustmentBehavior = try value(forSymbol: "contentInsetAdjustmentBehavior") as!
                UIScrollViewContentInsetAdjustmentBehavior
            switch contentInsetAdjustmentBehavior {
            case .automatic, .scrollableAxes:
                var contentInset = contentInset
                var contentSize: CGSize = .zero
                if hasExpression("contentSize"), !_evaluating.contains("contentSize") {
                    contentSize = try value(forSymbol: "contentSize.width") as! CGSize
                }
                if hasExpression("contentSize.width"), !_evaluating.contains("contentSize.width") {
                    contentSize.width = try cgFloatValue(forSymbol: "contentSize.width")
                }
                if hasExpression("contentSize.height"), !_evaluating.contains("contentSize.height") {
                    contentSize.height = try cgFloatValue(forSymbol: "contentSize.height")
                }
                var size: CGSize = .zero
                if hasExpression("width"), !_evaluating.contains("width") {
                    size.width = try cgFloatValue(forSymbol: "width")
                }
                if hasExpression("height"), !_evaluating.contains("height") {
                    size.height = try cgFloatValue(forSymbol: "height")
                }
                let safeAreaInsets = view._safeAreaInsets
                let alwaysBounceHorizontal = try value(forSymbol: "alwaysBounceHorizontal") as! Bool
                if alwaysBounceHorizontal || contentSize.width > size.width {
                    contentInset.left += safeAreaInsets.left
                    contentInset.right += safeAreaInsets.right
                }
                let alwaysBounceVertical = try value(forSymbol: "alwaysBounceVertical") as! Bool
                if alwaysBounceVertical || contentSize.height > size.height ||
                    contentInsetAdjustmentBehavior == .automatic {
                    contentInset.top += safeAreaInsets.top
                    contentInset.bottom += safeAreaInsets.bottom
                }
                return contentInset
            case .never:
                return contentInset
            case .always:
                let safeAreaInsets = view._safeAreaInsets
                return UIEdgeInsets(
                    top: contentInset.top + safeAreaInsets.top,
                    left: contentInset.left + safeAreaInsets.left,
                    bottom: contentInset.bottom + safeAreaInsets.bottom,
                    right: contentInset.right + safeAreaInsets.right
                )
            }
        }
        return contentInset
    }

    private func computeExplicitWidth() throws -> CGFloat? {
        if !_evaluating.contains("width"),
            !_evaluating.contains("height") || !value(forSymbol: "width", dependsOn: "height") {
            return try cgFloatValue(forSymbol: "width")
        }
        if hasExpression("contentSize.width"), !_evaluating.contains("contentSize.width") {
            let contentInset = try computeContentInset()
            return try cgFloatValue(forSymbol: "contentSize.width") + contentInset.left + contentInset.right
        }
        if hasExpression("contentSize"), !_evaluating.contains("contentSize") {
            let contentInset = try computeContentInset()
            let contentSize = try value(forSymbol: "contentSize") as! CGSize
            return contentSize.width + contentInset.left + contentInset.right
        }
        return nil
    }

    private func computeExplicitHeight() throws -> CGFloat? {
        if !_evaluating.contains("height"),
            !_evaluating.contains("width") || !value(forSymbol: "height", dependsOn: "width") {
            return try cgFloatValue(forSymbol: "height")
        }
        if hasExpression("contentSize.height"), !_evaluating.contains("contentSize.height") {
            let contentInset = try computeContentInset()
            return try cgFloatValue(forSymbol: "contentSize.height") + contentInset.top + contentInset.bottom
        }
        if hasExpression("contentSize"), !_evaluating.contains("contentSize") {
            let contentInset = try computeContentInset()
            let contentSize = try value(forSymbol: "contentSize") as! CGSize
            return contentSize.height + contentInset.top + contentInset.left
        }
        return nil
    }

    private func inferSize() throws -> CGSize {
        guard let _view = _view else { return .zero }
        let intrinsicSize = _view.intrinsicContentSize
        // TODO: remove special case
        if _view is UICollectionView {
            return intrinsicSize
        }
        // Try AutoLayout
        if _usesAutoLayout {
            defer { _updateLock -= 1 }
            _updateLock += 1
            let transform = _view.layer.transform
            _view.layer.transform = CATransform3DIdentity
            let frame = _view.frame
            let usesAutoresizing = _view.translatesAutoresizingMaskIntoConstraints
            _view.translatesAutoresizingMaskIntoConstraints = false
            if let width = try computeExplicitWidth() {
                _widthConstraint?.constant = width
                _widthConstraint?.isActive = true
            } else if intrinsicSize.width != UIViewNoIntrinsicMetric,
                _view.constraints.contains(where: { $0.firstAttribute == .width }) {
                _widthConstraint?.constant = intrinsicSize.width
                _widthConstraint?.isActive = true
            } else {
                _widthConstraint?.isActive = false
            }
            if let height = try computeExplicitHeight() {
                _heightConstraint?.constant = height
                _heightConstraint?.isActive = true
            } else if intrinsicSize.height != UIViewNoIntrinsicMetric,
                _view.constraints.contains(where: { $0.firstAttribute == .height }) {
                _widthConstraint?.constant = intrinsicSize.height
                _widthConstraint?.isActive = true
            } else {
                _heightConstraint?.isActive = false
            }
            _view.layoutIfNeeded()
            let size = _view.frame.size
            if usesAutoresizing {
                _widthConstraint?.isActive = false
                _heightConstraint?.isActive = false
                _view.translatesAutoresizingMaskIntoConstraints = true
                _view.frame = frame
            }
            _view.layer.transform = transform
            if size.width > 0 || size.height > 0 {
                return size
            }
        }
        // Try intrinsic size
        var size = intrinsicSize
        if size.width != UIViewNoIntrinsicMetric || size.height != UIViewNoIntrinsicMetric {
            let explicitWidth = try computeExplicitWidth()
            if let explicitWidth = explicitWidth {
                size.width = explicitWidth
            }
            let explicitHeight = try computeExplicitHeight()
            if let explicitHeight = explicitHeight {
                size.height = explicitHeight
            }
            let fittingSize = _view.sizeThatFits(size)
            if explicitWidth == nil, fittingSize.width > intrinsicSize.width {
                size.width = fittingSize.width
            }
            if explicitHeight == nil, fittingSize.height > intrinsicSize.height {
                size.height = fittingSize.height
            }
            // TODO: remove special case
            if _view is UITableViewHeaderFooterView, !children.isEmpty {
                let inferredSize = try inferContentSize()
                if inferredSize.height > 0 {
                    size.height = inferredSize.height
                }
            }
            return size
        }
        // Try best fit for content
        size = try inferContentSize()
        let contentInset = try computeContentInset()
        return CGSize(
            width: size.width + contentInset.left + contentInset.right,
            height: size.height + contentInset.top + contentInset.bottom
        )
    }

    // AutoLayout support
    private var _topConstraint: NSLayoutConstraint?
    private var _leftConstraint: NSLayoutConstraint?
    private var _widthConstraint: NSLayoutConstraint?
    private var _heightConstraint: NSLayoutConstraint?

    // Depends on parent view - must be called again if parent view changes
    private func setUpPositionConstraints() {
        assert(_topConstraint == nil)
        if let parentView = parent?._view, !(parentView is UIStackView) {
            _topConstraint = _view?.topAnchor.constraint(equalTo: parentView.topAnchor, constant: 0)
            _topConstraint?.identifier = "LayoutTop"
            _leftConstraint = _view?.leftAnchor.constraint(equalTo: parentView.leftAnchor, constant: 0)
            _leftConstraint?.identifier = "LayoutLeft"
        }
    }

    // Prevent `update()` from being called when making changes to view properties, etc
    private var _updateLock = 0
    func performWithoutUpdate(_ block: () throws -> Void) rethrows {
        defer { _updateLock -= 1 }
        _updateLock += 1
        try block()
    }

    // Note: thrown error is always a LayoutError
    private func updateValues(animated: Bool) throws {
        guard _updateLock == 0 else { return }
        defer { _updateLock -= 1 }
        _updateLock += 1
        try LayoutError.wrap(setUpExpressions, for: self)
        clearCachedValues()
        try LayoutError.wrap({
            try _updateExpressionValues(animated)
        }, for: self)
        for child in children {
            try LayoutError.wrap({
                try child.updateValues(animated: animated)
            }, for: self)
        }
    }

    // Note: thrown error is always a LayoutError
    private func updateFrame() throws {
        guard _updateLock == 0, let _view = _view else { return }
        let frame: CGRect
        defer {
            if parent == nil, _previousBounds != _view.bounds {
                _view.superview?.setNeedsLayout()
            }
            _previousBounds = CGRect(
                origin: _view.bounds.origin,
                size: frame.size
            )
            _updateLock -= 1
        }
        _updateLock += 1
        frame = self.frame
        if frame != _view.frame {
            if _view.translatesAutoresizingMaskIntoConstraints {
                let transform = _view.layer.transform
                _view.layer.transform = CATransform3DIdentity
                _view.frame = frame
                _view.layer.transform = transform
            } else {
                _widthConstraint?.constant = frame.width
                _widthConstraint?.isActive = true
                _heightConstraint?.constant = frame.height
                _heightConstraint?.isActive = true
                _leftConstraint?.constant = frame.origin.x
                _leftConstraint?.isActive = true
                _topConstraint?.constant = frame.origin.y
                _topConstraint?.isActive = true
                _view.updateConstraintsIfNeeded()
            }
        }
        if viewClass == UIScrollView.self, // Skip this behavior for subclasses like UITableView
            let scrollView = _view as? UIScrollView {
            let oldContentSize = scrollView.contentSize
            var contentSize = try value(forSymbol: "contentSize") as! CGSize
            if hasExpression("contentSize.width") {
                contentSize.width = try cgFloatValue(forSymbol: "contentSize.width")
            }
            if hasExpression("contentSize.height") {
                contentSize.height = try cgFloatValue(forSymbol: "contentSize.height")
            }
            if !contentSize.isNearlyEqual(to: oldContentSize) {
                scrollView.contentSize = contentSize
            }
        }
        for child in children {
            try LayoutError.wrap(child.updateFrame, for: self)
        }
        _view.layoutIfNeeded()
        _view.didUpdateLayout(for: self)
        _view.viewController?.didUpdateLayout(for: self)
        try throwUnhandledError()
    }

    /// Re-evaluates all expressions for the node and its children
    private func update(animated: Bool) {
        attempt {
            try updateValues(animated: animated)
            try updateFrame()
        }
    }

    /// Re-evaluates all expressions for the node and its children
    /// Note: thrown error is always a LayoutError
    public func update() {
        update(animated: false)
    }

    // MARK: binding

    /// Mounts a node inside the specified view controller, and binds the VC as its owner
    /// Note: thrown error is always a LayoutError
    public func mount(in viewController: UIViewController) throws {
        guard parent == nil else {
            throw LayoutError.message("The mount() method should only be used on a root node.")
        }
        try bind(to: viewController)
        for controller in viewControllers {
            viewController.addChildViewController(controller)
        }
        viewController.view.addSubview(view)
        performWithoutUpdate {
            _view?.frame = viewController.view.bounds
        }
        update()
    }

    /// Mounts a node inside the specified view, and binds the view as its owner
    /// Note: thrown error is always a LayoutError
    @nonobjc public func mount(in view: UIView) throws {
        guard parent == nil else {
            throw LayoutError.message("The mount() method should only be used on a root node.")
        }
        do {
            try bind(to: view)
        } catch let outerError {
            guard let viewController = view.viewController else {
                throw outerError
            }
            if (try? bind(to: viewController)) == nil {
                throw outerError
            }
        }
        if let viewController = view.viewController {
            for controller in viewControllers {
                viewController.addChildViewController(controller)
            }
        }
        _view.map { view.addSubview($0) }
        update()
    }

    /// Unmounts and unbinds the node from its owner
    public func unmount() {
        guard parent == nil else {
            // If not a root node, treat the same as `removeFromParent()`
            // TODO: should this be an error instead?
            removeFromParent()
            return
        }
        unbind()
        for controller in viewControllers {
            controller.removeFromParentViewController()
        }
        _view?.removeFromSuperview()
    }

    private weak var _owner: NSObject?

    /// Binds the node to the specified owner but doesn't attach the view or view controller(s)
    /// Note: thrown error is always a LayoutError
    public func bind(to owner: NSObject) throws {
        guard _owner == nil || _owner == owner || _owner == _viewController else {
            throw LayoutError("Cannot re-bind an already bound node.", for: self)
        }
        let oldDelegate = _delegate
        if oldDelegate == nil {
            _delegate = owner as? LayoutDelegate
        }
        if viewControllerClass != nil, owner != _viewController, let viewController = viewController {
            do {
                try bind(to: viewController)
                return
            } catch {
                if "\(error)".contains("@objc") {
                    throw error
                }
                unbind()
            }
        }
        _delegate = oldDelegate
        _owner = owner
        if parent == nil {
            if _setupComplete {
                cleanUp(recursive: true)
            } else {
                try completeSetup()
            }
        }
        if let outlet = outlet {
            guard let type = Swift.type(of: owner).allPropertyTypes()[outlet] else {
                let mirror = Mirror(reflecting: owner)
                if mirror.children.contains(where: { $0.label == outlet }) {
                    throw LayoutError("\(owner.classForCoder) \(outlet) outlet must be prefixed with @objc or @IBOutlet to be used with Layout")
                }
                throw LayoutError("\(owner.classForCoder) does not have an outlet named \(outlet)", for: self)
            }
            var didMatch = false
            var expectedType = "UIView or LayoutNode"
            if viewController != nil {
                expectedType = "UIViewController, \(expectedType)"
            }
            if type.matches(LayoutNode.self) {
                if type.matches(self) {
                    owner.setValue(self, forKey: outlet)
                    didMatch = true
                } else {
                    expectedType = "\(Swift.type(of: self))"
                }
            } else if type.matches(UIView.self) {
                if type.matches(view) {
                    owner.setValue(view, forKey: outlet)
                    didMatch = true
                } else {
                    expectedType = "\(viewClass)"
                }
            } else if let viewController = viewController, type.matches(UIViewController.self) {
                if type.matches(viewController) {
                    owner.setValue(viewController, forKey: outlet)
                    didMatch = true
                } else {
                    expectedType = "\(_class)"
                }
            }
            if !didMatch {
                throw LayoutError("outlet \(outlet) of \(owner.classForCoder) is not a \(expectedType)", for: self)
            }
        }
        for (name, type) in viewExpressionTypes where expressions[name] == nil {
            guard case .protocol = type.type, type.matches(owner),
                name == "delegate" || name == "dataSource" ||
                name.hasSuffix("Delegate") || name.hasSuffix("DataSource") else {
                continue
            }
            try LayoutError.wrap({
                try self._view?.setValue(owner, forExpression: name)
            }, for: self)
        }
        try bindActions()
        for child in children {
            try LayoutError.wrap({ try child.bind(to: owner) }, for: self)
        }
        try throwUnhandledError()
    }

    /// Unbinds the node from its owner but doesn't remove
    /// the view or view controller(s) from their respective parents
    public func unbind() {
        if let owner = _owner {
            if let outlet = outlet, type(of: owner).allPropertyTypes()[outlet] != nil {
                owner.setValue(nil, forKey: outlet)
            }
            if let control = view as? UIControl {
                control.unbindActions(for: owner)
            }
            if let viewController = _viewController {
                viewController.navigationItem.leftBarButtonItem?.unbindAction(for: owner)
                viewController.navigationItem.rightBarButtonItem?.unbindAction(for: owner)
            }
            _owner = nil
        }
        for child in children {
            child.unbind()
        }
        cleanUp(recursive: false)
    }

    private func bindActions() throws {
        guard let owner = _owner else { return }
        guard let control = _view as? UIControl else {
            if let navigationItem = _viewController?.navigationItem {
                if let buttonItem = navigationItem.leftBarButtonItem {
                    try buttonItem.bindAction(for: owner)
                }
                if let buttonItem = navigationItem.rightBarButtonItem {
                    try buttonItem.bindAction(for: owner)
                }
            }
            return
        }
        do {
            try control.bindActions(for: owner)
        } catch {
            if let delegate = delegate {
                try LayoutError.wrap({ try control.bindActions(for: delegate) }, for: self)
                return
            }
            throw LayoutError(error, for: self)
        }
    }
}

private let layoutSymbols: Set<String> = [
    "left", "right", "width", "top", "bottom", "height",
]

private func areEqual(_ lhs: Any, _ rhs: Any) -> Bool {
    if let lhs = lhs as? AnyHashable, let rhs = rhs as? AnyHashable {
        return lhs == rhs
    }
    return false // Can't compare equality
}
