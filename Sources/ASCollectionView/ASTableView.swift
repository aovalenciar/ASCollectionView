// ASCollectionView. Created by Apptek Studios 2019

import Combine
import SwiftUI

@available(iOS 13.0, *)
extension ASTableView where SectionID == Int
{
	/**
	 Initializes a  table view with a single section.

	 - Parameters:
	 - section: A single section (ASTableViewSection)
	 */
	public init(style: UITableView.Style = .plain, selectedItems: Binding<IndexSet>? = nil, section: Section)
	{
		self.style = style
		self.selectedItems = selectedItems.map
		{ selectedItems in
			Binding(
				get: { [:] },
				set: { selectedItems.wrappedValue = $0.first?.value ?? [] })
		}
		sections = [section]
	}

	/**
	 Initializes a  table view with a single section.
	 */
	public init<Data, DataID: Hashable, Content: View>(
		style: UITableView.Style = .plain,
		data: [Data],
		dataID dataIDKeyPath: KeyPath<Data, DataID>,
		selectedItems: Binding<IndexSet>? = nil,
		@ViewBuilder contentBuilder: @escaping ((Data, CellContext) -> Content))
	{
		self.style = style
		let section = ASTableViewSection(
			id: 0,
			data: data,
			dataID: dataIDKeyPath,
			contentBuilder: contentBuilder)
		sections = [section]
		self.selectedItems = selectedItems.map
		{ selectedItems in
			Binding(
				get: { [:] },
				set: { selectedItems.wrappedValue = $0.first?.value ?? [] })
		}
	}

	/**
	 Initializes a  table view with a single section of static content
	 */
	public static func `static`(@ViewArrayBuilder staticContent: () -> ViewArrayBuilder.Wrapper) -> ASTableView
	{
		ASTableView(
			style: .plain,
			sections: [ASTableViewSection(id: 0, content: staticContent)])
	}
    
    public func tableViewHeader<Content: View>(height: CGFloat, content: () -> Content?) -> Self
    {
        var tableView = self
        tableView.setHeaderView(content())
        tableView.tableViewHeaderHeight = height
        return tableView
    }
    
    fileprivate mutating func setHeaderView<Content: View>(_ view: Content?)
    {
        guard let view = view else { return }
        tableViewHeader = AnyView(view)
    }
}

@available(iOS 13.0, *)
public typealias ASTableViewSection = ASSection

@available(iOS 13.0, *)
public struct ASTableView<SectionID: Hashable>: UIViewControllerRepresentable
{
	// MARK: Type definitions

	public typealias Section = ASTableViewSection<SectionID>

	// MARK: Key variables

	public var sections: [Section]
	public var style: UITableView.Style
	public var selectedItems: Binding<[SectionID: IndexSet]>?

	// MARK: Environment variables

	@Environment(\.tableViewSeparatorsEnabled) private var separatorsEnabled
	@Environment(\.onPullToRefresh) private var onPullToRefresh
	@Environment(\.tableViewOnReachedBottom) private var onReachedBottom
    @Environment(\.tableViewOnScroll) private var onScroll
    @Environment(\.tableViewOnBeginScroll) private var onBeginScroll
	@Environment(\.scrollIndicatorsEnabled) private var scrollIndicatorsEnabled
	@Environment(\.contentInsets) private var contentInsets
	@Environment(\.alwaysBounceVertical) private var alwaysBounceVertical
	@Environment(\.editMode) private var editMode
	@Environment(\.animateOnDataRefresh) private var animateOnDataRefresh
    @Environment(\.initialIndexPath) private var initialIndexPath
    
    // Other
    var tableViewHeader: AnyView?
    var tableViewHeaderHeight: CGFloat = 0

	/**
	 Initializes a  table view with the given sections

	 - Parameters:
	 - sections: An array of sections (ASTableViewSection)
	 */
	@inlinable public init(style: UITableView.Style = .plain, selectedItems: Binding<[SectionID: IndexSet]>? = nil, sections: [Section])
	{
		self.style = style
		self.selectedItems = selectedItems
		self.sections = sections
	}

	@inlinable public init(style: UITableView.Style = .plain, selectedItems: Binding<[SectionID: IndexSet]>? = nil, @SectionArrayBuilder <SectionID> sectionBuilder: () -> [Section])
	{
		self.style = style
		self.selectedItems = selectedItems
		sections = sectionBuilder()
	}

	public func makeUIViewController(context: Context) -> AS_TableViewController
	{
		context.coordinator.parent = self

		let tableViewController = AS_TableViewController(style: style, tableViewHeaderHeight: tableViewHeaderHeight, tableHeaderView: tableViewHeader)
		tableViewController.coordinator = context.coordinator

		updateTableViewSettings(tableViewController.tableView)
		context.coordinator.tableViewController = tableViewController

		context.coordinator.setupDataSource(forTableView: tableViewController.tableView)
		return tableViewController
	}

	public func updateUIViewController(_ tableViewController: AS_TableViewController, context: Context)
	{
		context.coordinator.parent = self
		updateTableViewSettings(tableViewController.tableView)
		context.coordinator.updateContent(tableViewController.tableView, animated: animateOnDataRefresh, refreshExistingCells: true)
		context.coordinator.configureRefreshControl(for: tableViewController.tableView)
	}

	func updateTableViewSettings(_ tableView: UITableView)
	{
		tableView.backgroundColor = (style == .plain) ? .clear : .systemGroupedBackground
		tableView.separatorStyle = separatorsEnabled ? .singleLine : .none
		tableView.contentInset = contentInsets
		tableView.alwaysBounceVertical = alwaysBounceVertical
		tableView.showsVerticalScrollIndicator = scrollIndicatorsEnabled
		tableView.showsHorizontalScrollIndicator = scrollIndicatorsEnabled

		let isEditing = editMode?.wrappedValue.isEditing ?? false
		tableView.allowsSelection = isEditing
		tableView.allowsMultipleSelection = isEditing
	}

	public func makeCoordinator() -> Coordinator
	{
		Coordinator(self)
	}

	public class Coordinator: NSObject, ASTableViewCoordinator, UITableViewDelegate, UITableViewDataSourcePrefetching
	{
		var parent: ASTableView
		weak var tableViewController: AS_TableViewController?

		var dataSource: ASTableViewDiffableDataSource<SectionID, ASCollectionViewItemUniqueID>?

		let cellReuseID = UUID().uuidString
		let supplementaryReuseID = UUID().uuidString

		// MARK: Private tracking variables

		private var hasDoneInitialSetup = false
		
		// MARK: Caching
		private var cachedHostingControllers: [ASCollectionViewItemUniqueID: ASHostingControllerProtocol] = [:]

		typealias Cell = ASTableViewCell

		init(_ parent: ASTableView)
        {
            self.parent = parent
            super.init()
            self.setUpNotifications()
        }

		func sectionID(fromSectionIndex sectionIndex: Int) -> SectionID?
		{
			parent.sections[safe: sectionIndex]?.id
		}

		func section(forItemID itemID: ASCollectionViewItemUniqueID) -> Section?
		{
			parent.sections
				.first(where: { $0.id.hashValue == itemID.sectionIDHash })
		}

		func setupDataSource(forTableView tv: UITableView)
		{
			tv.delegate = self
			tv.prefetchDataSource = self
			tv.register(Cell.self, forCellReuseIdentifier: cellReuseID)
			tv.register(ASTableViewSupplementaryView.self, forHeaderFooterViewReuseIdentifier: supplementaryReuseID)

			dataSource = .init(tableView: tv)
			{ [weak self] (tableView, indexPath, itemID) -> UITableViewCell? in
				guard let self = self else { return nil }
				let isSelected = tableView.indexPathsForSelectedRows?.contains(indexPath) ?? false
				guard
					let cell = tableView.dequeueReusableCell(withIdentifier: self.cellReuseID, for: indexPath) as? Cell
				else { return nil }

				guard let section = self.parent.sections[safe: indexPath.section] else { return cell }
				
				// Cell layout invalidation callback
				cell.invalidateLayout = { [weak tv] in
					tv?.beginUpdates()
					tv?.endUpdates()
				}

				// Self Sizing Settings
				let selfSizingContext = ASSelfSizingContext(cellType: .content, indexPath: indexPath)
				cell.selfSizingConfig =
					section.dataSource.getSelfSizingSettings(context: selfSizingContext)
						?? ASSelfSizingConfig(selfSizeHorizontally: false, selfSizeVertically: true)

				// Check if there is a cached host controller
				let cachedHC = self.cachedHostingControllers[itemID]
				
				// Configure cell
				section.dataSource.configureCell(cell, usingCachedController: cachedHC, forItemID: itemID, isSelected: isSelected)

				// Cache the HC if needed
				if section.shouldCacheCells {
					self.cachedHostingControllers[itemID] = cell.hostingController
				}
				
				return cell
			}
			dataSource?.defaultRowAnimation = .fade
		}

		func populateDataSource(animated: Bool = true)
		{
			var snapshot = NSDiffableDataSourceSnapshot<SectionID, ASCollectionViewItemUniqueID>()
			snapshot.appendSections(parent.sections.map { $0.id })
			parent.sections.forEach
			{
				snapshot.appendItems($0.itemIDs, toSection: $0.id)
			}
			dataSource?.apply(snapshot, animatingDifferences: animated)
		}

		func updateContent(_ tv: UITableView, animated: Bool, refreshExistingCells: Bool)
		{
			guard hasDoneInitialSetup else { return }
			if refreshExistingCells
			{
				tv.visibleCells.forEach
				{ cell in
					guard
						let cell = cell as? Cell,
						let itemID = cell.id
					else { return }

					// Check if there is a cached host controller
					let cachedHC = self.cachedHostingControllers[itemID]
					// Configure cell
					section(forItemID: itemID)?.dataSource.configureCell(cell, usingCachedController: cachedHC, forItemID: itemID, isSelected: cell.isSelected)
				}
			}
			populateDataSource(animated: animated)
			updateSelectionBindings(tv)
		}

		func onMoveToParent(tableViewController: AS_TableViewController)
		{
			if !hasDoneInitialSetup
			{
				hasDoneInitialSetup = true

				// Populate data source
				populateDataSource(animated: false)
                
                // Set initial scroll position
                parent.initialIndexPath.map { scrollToIndexPath($0, animated: false) }

				// Check if reached bottom already
				checkIfReachedBottom(tableViewController.tableView)
			}
		}

		func onMoveFromParent()
		{
			hasDoneInitialSetup = false
		}

		func configureRefreshControl(for tv: UITableView)
		{
			guard parent.onPullToRefresh != nil else
			{
				if tv.refreshControl != nil
				{
					tv.refreshControl = nil
				}
				return
			}
			if tv.refreshControl == nil
			{
				let refreshControl = UIRefreshControl()
				refreshControl.addTarget(self, action: #selector(tableViewDidPullToRefresh), for: .valueChanged)
				tv.refreshControl = refreshControl
			}
		}
        
        // MARK: Functions for determining scroll position (on appear, and also on orientation change)

        func scrollToIndexPath(_ indexPath: IndexPath, animated: Bool = false)
        {
            tableViewController?.tableView.scrollToRow(at: indexPath, at: .middle, animated: animated)
        }

		@objc
		public func tableViewDidPullToRefresh()
		{
			guard let tableView = tableViewController?.tableView else { return }
			let endRefreshing: (() -> Void) = { [weak tableView] in
				tableView?.refreshControl?.endRefreshing()
			}
			parent.onPullToRefresh?(endRefreshing)
		}

		public func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat
		{
			parent.sections[safe: indexPath.section]?.estimatedRowHeight ?? 50
		}

		public func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath)
		{
			(cell as? Cell)?.willAppear(in: tableViewController)
			parent.sections[safe: indexPath.section]?.dataSource.onAppear(indexPath)
		}

		public func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath)
		{
			(cell as? Cell)?.didDisappear()
			parent.sections[safe: indexPath.section]?.dataSource.onDisappear(indexPath)
		}

		public func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int)
		{
			(view as? ASTableViewSupplementaryView)?.willAppear(in: tableViewController)
		}

		public func tableView(_ tableView: UITableView, didEndDisplayingHeaderView view: UIView, forSection section: Int)
		{
			(view as? ASTableViewSupplementaryView)?.didDisappear()
		}

		public func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int)
		{
			(view as? ASTableViewSupplementaryView)?.willAppear(in: tableViewController)
		}

		public func tableView(_ tableView: UITableView, didEndDisplayingFooterView view: UIView, forSection section: Int)
		{
			(view as? ASTableViewSupplementaryView)?.didDisappear()
		}

		public func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath])
		{
			let itemIDsToPrefetchBySection: [Int: [IndexPath]] = Dictionary(grouping: indexPaths) { $0.section }
			itemIDsToPrefetchBySection.forEach
			{
				parent.sections[safe: $0.key]?.dataSource.prefetch($0.value)
			}
		}

		public func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath])
		{
			let itemIDsToCancelPrefetchBySection: [Int: [IndexPath]] = Dictionary(grouping: indexPaths) { $0.section }
			itemIDsToCancelPrefetchBySection.forEach
			{
				parent.sections[safe: $0.key]?.dataSource.cancelPrefetch($0.value)
			}
		}

		// MARK: Swipe actions

		public func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration?
		{
			guard parent.sections[safe: indexPath.section]?.dataSource.supportsDelete(at: indexPath) == true else { return nil }
			let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completionHandler in
				self?.onDeleteAction(indexPath: indexPath, completionHandler: completionHandler)
			}
			return UISwipeActionsConfiguration(actions: [deleteAction])
		}

		public func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle
		{
			.none
		}

		private func onDeleteAction(indexPath: IndexPath, completionHandler: (Bool) -> Void)
		{
			parent.sections[safe: indexPath.section]?.dataSource.onDelete(indexPath: indexPath, completionHandler: completionHandler)
		}
        
        //MARK: Notification Center
        
        func setUpNotifications() {
            NotificationCenter.default.addObserver(self, selector: #selector(asTableViewShouldScrollToSectionNotification(notif:)), name: .ASTableViewShouldScrollToSectionNotification, object: nil)
        }
        
        func removeNotifications() {
            NotificationCenter.default.removeObserver(self)
        }
        
        @objc func asTableViewShouldScrollToSectionNotification(notif: Notification) {
            
            guard let section = notif.object as? Int,
                parent.sections.count > section else {return}
            
            var animated = true
            
            if let animatedInfo = notif.userInfo?[Notification.ASKey.ScrollAnimated] as? Bool {
                animated = animatedInfo
            }
            
            //scroll to the specified section
            let sectionIndexPath = IndexPath(row: NSNotFound, section: section)
            tableViewController?.tableView.scrollToRow(at: sectionIndexPath, at: .top, animated: animated)
        }

		// MARK: Cell Selection

		public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath)
		{
			guard
				let cell = tableView.cellForRow(at: indexPath) as? Cell,
				let itemID = cell.id
			else { return }
			updateSelectionBindings(tableView)
			
			// Check if there is a cached host controller
			let cachedHC = self.cachedHostingControllers[itemID]
			// Configure cell
			section(forItemID: itemID)?.dataSource.configureCell(cell, usingCachedController: cachedHC, forItemID: itemID, isSelected: cell.isSelected)
		}

		public func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath)
		{
			guard
				let cell = tableView.cellForRow(at: indexPath) as? Cell,
				let itemID = cell.id
			else { return }
			updateSelectionBindings(tableView)
			
			// Check if there is a cached host controller
			let cachedHC = self.cachedHostingControllers[itemID]
			// Configure cell
			section(forItemID: itemID)?.dataSource.configureCell(cell, usingCachedController: cachedHC, forItemID: itemID, isSelected: cell.isSelected)
		}

		func updateSelectionBindings(_ tableView: UITableView)
		{
			guard let selectedItemsBinding = parent.selectedItems else { return }
			let selected = tableView.indexPathsForSelectedRows ?? []
			let selectedSafe = selected.filter { parent.sections.containsIndex($0.section) }
			let selectedBySection = Dictionary(grouping: selectedSafe)
			{
				parent.sections[$0.section].id
			}.mapValues
			{
				IndexSet($0.map { $0.item })
			}
			DispatchQueue.main.async
			{
				selectedItemsBinding.wrappedValue = selectedBySection
			}
		}

		public func tableView(_ tableView: UITableView, estimatedHeightForHeaderInSection section: Int) -> CGFloat
		{
			guard parent.sections[safe: section]?.supplementary(ofKind: UICollectionView.elementKindSectionHeader) != nil else
			{
				return CGFloat.leastNormalMagnitude
			}
			return parent.sections[safe: section]?.estimatedHeaderHeight ?? 50
		}

		public func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat
		{
			guard parent.sections[safe: section]?.supplementary(ofKind: UICollectionView.elementKindSectionHeader) != nil else
			{
				return CGFloat.leastNormalMagnitude
			}
			return UITableView.automaticDimension
		}

		public func tableView(_ tableView: UITableView, estimatedHeightForFooterInSection section: Int) -> CGFloat
		{
			guard parent.sections[safe: section]?.supplementary(ofKind: UICollectionView.elementKindSectionFooter) != nil else
			{
				return CGFloat.leastNormalMagnitude
			}
			return parent.sections[safe: section]?.estimatedFooterHeight ?? 50
		}

		public func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat
		{
			guard parent.sections[safe: section]?.supplementary(ofKind: UICollectionView.elementKindSectionFooter) != nil else
			{
				return CGFloat.leastNormalMagnitude
			}
			return UITableView.automaticDimension
		}

		public func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView?
		{
			guard let reusableView = tableView.dequeueReusableHeaderFooterView(withIdentifier: supplementaryReuseID) as? ASTableViewSupplementaryView
			else { return nil }
			if let supplementaryView = parent.sections[safe: section]?.supplementary(ofKind: UICollectionView.elementKindSectionHeader)
			{
				// Self Sizing Settings
				let selfSizingContext = ASSelfSizingContext(cellType: .supplementary(UICollectionView.elementKindSectionHeader), indexPath: IndexPath(row: 0, section: section))
				reusableView.selfSizingConfig =
					parent.sections[safe: section]?.dataSource.getSelfSizingSettings(context: selfSizingContext)
						?? ASSelfSizingConfig(selfSizeHorizontally: false, selfSizeVertically: true)

				// Cell Content Setup
				reusableView.setupFor(
					id: section,
					view: supplementaryView)
			}
			return reusableView
		}

		public func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView?
		{
			guard let reusableView = tableView.dequeueReusableHeaderFooterView(withIdentifier: supplementaryReuseID) as? ASTableViewSupplementaryView
			else { return nil }
			if let supplementaryView = parent.sections[safe: section]?.supplementary(ofKind: UICollectionView.elementKindSectionFooter)
			{
				// Self Sizing Settings
				let selfSizingContext = ASSelfSizingContext(cellType: .supplementary(UICollectionView.elementKindSectionFooter), indexPath: IndexPath(row: 0, section: section))
				reusableView.selfSizingConfig =
					parent.sections[safe: section]?.dataSource.getSelfSizingSettings(context: selfSizingContext)
						?? ASSelfSizingConfig(selfSizeHorizontally: false, selfSizeVertically: true)

				// Cell Content Setup
				reusableView.setupFor(
					id: section,
					view: supplementaryView)
			}
			return reusableView
		}

		public func scrollViewDidScroll(_ scrollView: UIScrollView)
        {
            parent.onScroll(scrollView.contentOffset)
            checkIfReachedBottom(scrollView)
        }
        
        public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            parent.onBeginScroll()
        }

		var hasAlreadyReachedBottom: Bool = false
		func checkIfReachedBottom(_ scrollView: UIScrollView)
		{
			if (scrollView.contentSize.height - scrollView.contentOffset.y) <= scrollView.frame.size.height
			{
				if !hasAlreadyReachedBottom
				{
					hasAlreadyReachedBottom = true
					parent.onReachedBottom()
				}
			}
			else
			{
				hasAlreadyReachedBottom = false
			}
		}
        
        //MARK: - deinit
        
        deinit {
            removeNotifications()
        }
	}
}

@available(iOS 13.0, *)
protocol ASTableViewCoordinator: AnyObject
{
	func onMoveToParent(tableViewController: AS_TableViewController)
	func onMoveFromParent()
}

// MARK: ASTableView specific header modifiers

@available(iOS 13.0, *)
public extension ASTableViewSection {
	func sectionHeaderInsetGrouped<Content: View>(content: () -> Content?) -> Self
	{
		var section = self
		let insetGroupedContent =
			HStack {
				content()
				Spacer()
			}
			.font(.headline)
			.padding(EdgeInsets(top: 12, leading: 0, bottom: 6, trailing: 0))

		section.setHeaderView(insetGroupedContent)
		return section
	}
}

@available(iOS 13.0, *)
public class AS_TableViewController: UIViewController
{
	weak var coordinator: ASTableViewCoordinator?
	var style: UITableView.Style
    var tableHeaderView: AnyView?
    var tableViewHeaderHeight: CGFloat = 0

	lazy var tableView: UITableView = {
		let tableView = UITableView(frame: .zero, style: style)
        
		if let headerView = self.tableHeaderView {
            
            let vc = ASHostingController(headerView)
            vc.viewController.view.frame = CGRect(x: 0, y: 0, width: tableView.frame.width, height: self.tableViewHeaderHeight)
            vc.viewController.view.setNeedsLayout()
            vc.viewController.view.layoutIfNeeded()
            
            addChild(vc.viewController)
            
            tableView.tableHeaderView = vc.viewController.view
            
            vc.viewController.didMove(toParent: self)
            
        } else {
            tableView.tableHeaderView = UIView(frame: CGRect(origin: .zero, size: CGSize(width: CGFloat.leastNormalMagnitude, height: CGFloat.leastNormalMagnitude))) // Remove unnecessary padding in Style.grouped/insetGrouped
        }
        
		tableView.tableFooterView = UIView(frame: CGRect(origin: .zero, size: CGSize(width: CGFloat.leastNormalMagnitude, height: CGFloat.leastNormalMagnitude))) // Remove separators for non-existent cells
		return tableView
	}()

	public init(style: UITableView.Style, tableViewHeaderHeight: CGFloat, tableHeaderView: AnyView? = nil)
    {
        self.style = style
        self.tableHeaderView = tableHeaderView
        self.tableViewHeaderHeight = tableViewHeaderHeight
        super.init(nibName: nil, bundle: nil)
    }

	required init?(coder: NSCoder)
	{
		fatalError("init(coder:) has not been implemented")
	}

	public override func viewDidLoad()
	{
		super.viewDidLoad()
		view.backgroundColor = .clear
		view.addSubview(tableView)

		tableView.translatesAutoresizingMaskIntoConstraints = false
		NSLayoutConstraint.activate([tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0),
									 tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 0),
									 tableView.topAnchor.constraint(equalTo: view.topAnchor, constant: 0),
									 tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 0)])
	}

	public override func didMove(toParent parent: UIViewController?)
	{
		super.didMove(toParent: parent)
		if parent != nil
		{
			coordinator?.onMoveToParent(tableViewController: self)
		}
		else
		{
			coordinator?.onMoveFromParent()
		}
	}
}

@available(iOS 13.0, *)
class ASTableViewDiffableDataSource<SectionIdentifierType, ItemIdentifierType>: UITableViewDiffableDataSource<SectionIdentifierType, ItemIdentifierType> where SectionIdentifierType: Hashable, ItemIdentifierType: Hashable
{
	override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool
	{
		true
	}

	override func apply(_ snapshot: NSDiffableDataSourceSnapshot<SectionIdentifierType, ItemIdentifierType>, animatingDifferences: Bool = true, completion: (() -> Void)? = nil)
	{
		if animatingDifferences
		{
			super.apply(snapshot, animatingDifferences: true, completion: completion)
		}
		else
		{
			UIView.performWithoutAnimation {
				super.apply(snapshot, animatingDifferences: false, completion: completion)
			}
		}
	}
}
