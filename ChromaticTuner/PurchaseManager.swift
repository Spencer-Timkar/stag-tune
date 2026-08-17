import StoreKit
import SwiftUI

@MainActor
final class PurchaseManager: ObservableObject {
    static let proProductID = "com.spencer.stagtune.stagpro"

    @Published private(set) var proProduct: Product?
    @Published private(set) var isPro = false
    @Published private(set) var entitlementCheckComplete = false
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var productLoadComplete = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var message: String?

    private var transactionListener: Task<Void, Never>?
    private var productLoadTask: Task<Product?, Error>?

    var displayPrice: String? { proProduct?.displayPrice }
    var isProAvailable: Bool { proProduct != nil }

    init() {
        transactionListener = listenForTransactions()
        Task {
            await refreshStoreState()
        }
    }

    deinit {
        transactionListener?.cancel()
    }

    func purchasePro() async {
        message = nil
        if proProduct == nil { await loadProducts() }
        guard let proProduct else {
            message = unavailableMessage
            return
        }

        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await proProduct.purchase()
            switch result {
            case .success(let verification):
                let transaction = try verified(verification)
                await transaction.finish()
                await refreshEntitlements()
            case .pending:
                message = "Your purchase is awaiting approval."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch PurchaseError.failedVerification {
            message = "The App Store could not verify this purchase. No charge was applied."
        } catch {
            message = "The purchase could not be completed. Check your App Store connection and try again."
        }
    }

    /// Refreshes both the user's entitlement and the App Store product metadata.
    /// Call this when the app becomes active so TestFlight/App Store changes are
    /// picked up without requiring the user to relaunch the app.
    func refreshStoreState() async {
        await refreshEntitlements()
        await loadProducts()
    }

    func restorePurchases() async {
        message = nil
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            try await AppStore.sync()
            await refreshEntitlements()
            message = isPro ? "Stag Pro has been restored." : "No Stag Pro purchase was found."
        } catch {
            message = "Purchases could not be restored. Please try again."
        }
    }

    private func loadProducts() async {
        if let productLoadTask {
            await applyProductResult(from: productLoadTask)
            return
        }

        isLoadingProducts = true
        productLoadComplete = false
        let task = Task<Product?, Error> {
            try await Product.products(for: [Self.proProductID]).first
        }
        productLoadTask = task
        defer {
            productLoadTask = nil
            isLoadingProducts = false
            productLoadComplete = true
        }

        await applyProductResult(from: task)
    }

    private func applyProductResult(from task: Task<Product?, Error>) async {
        do {
            proProduct = try await task.value
            if proProduct == nil {
                message = unavailableMessage
            } else if message == unavailableMessage {
                message = nil
            }
        } catch {
            proProduct = nil
            message = "The App Store could not be reached. Check your connection and try again."
        }
    }

    private func refreshEntitlements() async {
        var ownsPro = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? verified(result) else { continue }
            if transaction.productID == Self.proProductID,
               transaction.revocationDate == nil {
                ownsPro = true
            }
        }
        isPro = ownsPro
        entitlementCheckComplete = true
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard let self,
                      let transaction = try? self.verified(result) else { continue }
                await transaction.finish()
                await self.refreshEntitlements()
            }
        }
    }

    private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified:
            throw PurchaseError.failedVerification
        }
    }

    private var unavailableMessage: String {
        "Stag Pro is not available from the App Store yet. Please try again later."
    }
}

private enum PurchaseError: Error {
    case failedVerification
}
