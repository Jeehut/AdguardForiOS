//
// This file is part of Adguard for iOS (https://github.com/AdguardTeam/AdguardForiOS).
// Copyright © Adguard Software Limited. All rights reserved.
//
// Adguard for iOS is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Adguard for iOS is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Adguard for iOS. If not, see <http://www.gnu.org/licenses/>.
//

import Foundation

enum TabBarTabs: Int {
    typealias RawValue = Int

    case mainTab = 0
    case protectionTab = 1
    case activityTab = 2
    case settingTab = 3
}

class MainTabBarController: UITabBarController, UITabBarControllerDelegate {

    private var bottomView: UIView?
    private let bottomLineHeight: CGFloat = 4.0

    private var bottomViewLeftAnchor: NSLayoutConstraint?

    private lazy var theme: ThemeServiceProtocol = { ServiceLocator.shared.getService()! }()

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self

        if tabBar.items == nil {
            return
        }

        for (index, item) in tabBar.items!.enumerated() {
            item.title = nil
            item.imageInsets = UIEdgeInsets(top: 6, left: 0, bottom: -6, right: 0)

            if index == TabBarTabs.mainTab.rawValue {
                item.accessibilityLabel = String.localizedString("main_page_tab")
                continue
            }

            if index == TabBarTabs.protectionTab.rawValue {
                item.accessibilityLabel = String.localizedString("protection_page_tab")
                continue
            }

            if index == TabBarTabs.activityTab.rawValue {
                item.accessibilityLabel = String.localizedString("activity_page_tab")
                continue
            }

            if index == TabBarTabs.settingTab.rawValue {
                item.accessibilityLabel = String.localizedString("settings_page_tab")
                continue
            }
        }

        updateTheme()
        createSelectionIndicator()
        addTabBarShadow()
    }

    override var selectedViewController: UIViewController? {
        didSet {
            if let item = tabBar.selectedItem {
                changeLeftAnchor(for: item)
            }
        }
    }

    override func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        changeLeftAnchor(for: item)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let item = tabBar.selectedItem else { return }
        resizeIndicator()
        changeLeftAnchor(for: item)
    }

    private func changeLeftAnchor(for item: UITabBarItem){
        let numberOfItems = CGFloat(tabBar.items!.count)
        let width: CGFloat = tabBar.frame.width / numberOfItems

        let selectedItem = tabBar.items?.firstIndex(of: item) ?? 0

        bottomViewLeftAnchor?.constant = width / 4 + CGFloat(selectedItem) * width

        UIView.animate(withDuration: 0.3) {[weak self] in
            self?.tabBar.layoutIfNeeded()
        }
    }

    private func addTabBarShadow(){
        tabBar.shadowImage = UIImage()
        tabBar.backgroundImage = UIImage()

        tabBar.layer.shadowColor = UIColor.black.cgColor
        tabBar.layer.shadowOpacity = 0.1
        tabBar.layer.shadowRadius = 2.0
    }

    private func createSelectionIndicator() {
        if bottomView != nil {
            return
        }

        bottomView = UIView()
        bottomView?.isUserInteractionEnabled = false
        bottomView?.translatesAutoresizingMaskIntoConstraints = false
        bottomView?.backgroundColor = UIColor.AdGuardColor.lightGreen1
        tabBar.addSubview(bottomView ?? UIView())

        let numberOfItems = CGFloat(tabBar.items!.count)

        let width: CGFloat = tabBar.frame.width / numberOfItems

        let mult = 1 / (numberOfItems * 2)

        bottomView?.heightAnchor.constraint(equalToConstant: bottomLineHeight).isActive = true
        bottomView?.widthAnchor.constraint(equalTo: tabBar.widthAnchor, multiplier: mult).isActive = true
        bottomViewLeftAnchor = bottomView?.leftAnchor.constraint(equalTo: tabBar.leftAnchor, constant: width / 4)
        bottomViewLeftAnchor?.isActive = true
        bottomView?.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor).isActive = true
    }

    private func resizeIndicator(){
        let bottomInset = tabBar.safeAreaInsets.bottom

        if bottomInset != 0.0 {
            bottomView?.isHidden = true
            return
        }

        let numberOfItems = CGFloat(tabBar.items!.count)
        let width: CGFloat = tabBar.frame.width / numberOfItems
        let bounds = CGRect(x: 0.0, y: 0.0, width: width / 2, height: bottomLineHeight)
        let maskPath1 = UIBezierPath(roundedRect: bounds,
            byRoundingCorners: [.topLeft , .topRight],
            cornerRadii: CGSize(width: 20, height: 20))
        let maskLayer = CAShapeLayer()
        maskLayer.frame = bounds
        maskLayer.path = maskPath1.cgPath
        bottomView?.layer.mask = maskLayer
    }

    func tabBarController(_ tabBarController: UITabBarController, animationControllerForTransitionFrom fromVC: UIViewController, to toVC: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        guard let fromVCIndex = tabBarController.viewControllers?.firstIndex(of: fromVC),
            let toVCIndex = tabBarController.viewControllers?.firstIndex(of: toVC) else {
                return nil
        }
        let edge: UIRectEdge = fromVCIndex > toVCIndex ? .right : .left

        return CustomNavigationTransitionAnimator(presenting: edge == .left)
    }

    // Set transitionCoordinator to nil to prevent controllers disappearing
    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        return transitionCoordinator == nil
    }
}

extension UITabBar {
    override open var traitCollection: UITraitCollection {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return UITraitCollection(horizontalSizeClass: .compact)
        }
        return super.traitCollection
    }
}

extension MainTabBarController: ThemableProtocol {
    func updateTheme(){
        tabBar.backgroundColor = theme.tabBarColor
        tabBar.barTintColor = theme.tabBarColor
    }
}

