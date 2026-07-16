import StoreKit
import SwiftUI

@MainActor
final class PurchaseManager: ObservableObject {
    static let proProductID = "com.spencer.stagtune.stagpro"

    @Published private(set) var proProduct: Product?
    @Published private(set) var isPro = false
    @Published private(set) var entitlementCheckComplete = false
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var message: String?

    private var transactionListener: Task<Void, Never>?

    var displayPrice: String { proProduct?.displayPrice ?? "$2.99" }

    init() {
        transactionListener = listenForTransactions()
        Task {
            await refreshEntitlements()
            await loadProducts()
        }
    }

    deinit {
        transactionListener?.cancel()
    }

    func purchasePro() async {
        message = nil
        if proProduct == nil { await loadProducts() }
        guard let proProduct else {
            message = "Stag Pro is temporarily unavailable. Please try again later."
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
                isPro = true
            case .pending:
                message = "Your purchase is awaiting approval."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = "The purchase could not be completed. Please try again."
        }
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
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            proProduct = try await Product.products(for: [Self.proProductID]).first
        } catch {
            proProduct = nil
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
}

private enum PurchaseError: Error {
    case failedVerification
}
