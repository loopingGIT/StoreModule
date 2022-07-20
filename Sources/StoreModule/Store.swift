//
//  Store.swift
//  
//
//  Created by augusto on 16/3/22.
//

import Foundation
import StoreKit

private class PurchasesMonitor {
    var purchaseHandler: ((String) -> Void)?

    func addPurchase(id: String) {
        purchaseHandler?(id)
    }
    
    func removePurchase(id: String) {
        purchaseHandler?(id)
    }
}

public class Store {
    
    public typealias Product = StoreKit.Product

    private(set) public var purchasedIdentifiers = Set<String>()

    private(set) var availableProducts = Set<Product>()

    private var updateListenerTask: Task<Void, Error>? = nil

    private let purchasesMonitor: PurchasesMonitor
        
    private(set) public var currentSubscription: Product? 
        
    public var purchasesStream: AsyncStream<String> {
        AsyncStream { continuation in
            purchasesMonitor.purchaseHandler = { quake in
                continuation.yield(quake)
            }
        }
    }

    public init() {
        purchasesMonitor = PurchasesMonitor()
        
        //Start a transaction listener as close to app launch as possible so you don't miss any transactions.
        updateListenerTask = listenForTransactions()
    }
    
    deinit {
        updateListenerTask?.cancel()
    }

    @MainActor
    public func requestProducts(identifiers: Set<String>) async throws -> [StoreKit.Product] {
        do {
            //Request products from the App Store using the identifiers defined in the Products.plist file.
            let products =  try await StoreKit.Product.products(for: identifiers)
            availableProducts = availableProducts.union(products)
                        
            return products
        } catch {
            print("Failed product request: \(error)")
            
            throw error
        }
    }
    
    @discardableResult
    public func purchase(productIdentifier: String) async throws -> Transaction {
        let product = availableProducts.first { $0.id == productIdentifier }
        
        guard let product = product else {
            throw StoreError.purchaseFailed(error: .productUnavailable)
        }
        
        return try await purchase(product)
    }
    
    @discardableResult
    public func purchase(_ product: StoreKit.Product) async throws -> Transaction {
        //Begin a purchase.
        let result = try await product.purchase()
        
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)

            if product.type == .autoRenewable {
                currentSubscription = product
            }
            
            //Deliver content to the user.
            await updatePurchasedIdentifiers(transaction)

            //Always finish a transaction.
            await transaction.finish()

            return transaction
        case .userCancelled, .pending:
            throw StoreError.purchaseFailed(result: result)
        @unknown default:
            throw StoreError.purchaseFailed(result: result)
        }
    }

    public func isPurchased(_ productIdentifier: String) async throws -> Bool {
        //Get the most recent transaction receipt for this `productIdentifier`.
        guard let result = await Transaction.latest(for: productIdentifier) else {
            //If there is no latest transaction, the product has not been purchased.
            return false
        }

        let transaction = try checkVerified(result)

        //Ignore revoked transactions, they're no longer purchased.

        //For subscriptions, a user can upgrade in the middle of their subscription period. The lower service
        //tier will then have the `isUpgraded` flag set and there will be a new transaction for the higher service
        //tier. Ignore the lower service tier transactions which have been upgraded.
        
        guard transaction.revocationDate == nil && !transaction.isUpgraded else {
            return false
        }
        
        await updatePurchasedIdentifiers(transaction)
        
        return true
    }
    
    public func isInTrial(_ productIdentifier: String) async throws -> Bool {
        //Get the most recent transaction receipt for this `productIdentifier`.
        guard let result = await Transaction.latest(for: productIdentifier) else {
            //If there is no latest transaction, the product has not been purchased.
            return false
        }

        let transaction = try checkVerified(result)

        //Ignore revoked transactions, they're no longer purchased.

        //For subscriptions, a user can upgrade in the middle of their subscription period. The lower service
        //tier will then have the `isUpgraded` flag set and there will be a new transaction for the higher service
        //tier. Ignore the lower service tier transactions which have been upgraded.
        
        guard transaction.revocationDate == nil && !transaction.isUpgraded else {
            return false
        }
                
        return transaction.offerType == .introductory
    }
    
    public func restorePurchases() async throws {
        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try self.checkVerified(result)

                //Deliver content to the user.
                await self.updatePurchasedIdentifiers(transaction)

                //Always finish a transaction.
                await transaction.finish()
            } catch {
                //StoreKit has a receipt it can read but it failed verification. Don't deliver content to the user.
                print("Transaction failed verification")
            }
        }
    }
       
    public func currentSubscriptionTransaction() async -> Transaction? {
        var transaction: Transaction?
        
        for product in availableProducts {
            guard let result = await Transaction.latest(for: product.id) else {
                continue
            }
            
            guard let productTransaction = try? self.checkVerified(result) else {
                continue
            }
            
            guard productTransaction.revocationDate == nil && !productTransaction.isUpgraded else {
                continue
            }
            
            transaction = productTransaction
            
            break
        }
        
        return transaction
    }
    
}

private extension Store {
    
    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        //Check if the transaction passes StoreKit verification.
        switch result {
        case .unverified:
            //StoreKit has parsed the JWS but failed verification. Don't deliver content to the user.
            throw StoreError.failedVerification
        case .verified(let safe):
            //If the transaction is verified, unwrap and return it.
            return safe
        }
    }

    @MainActor
    func updatePurchasedIdentifiers(_ transaction: Transaction) async {
        if transaction.revocationDate == nil {
            //If the App Store has not revoked the transaction, add it to the list of `purchasedIdentifiers`.
            purchasedIdentifiers.insert(transaction.productID)
            
            purchasesMonitor.addPurchase(id: transaction.productID)
        } else {
            //If the App Store has revoked this transaction, remove it from the list of `purchasedIdentifiers`.
            purchasedIdentifiers.remove(transaction.productID)
            
            purchasesMonitor.removePurchase(id: transaction.productID)
        }
    }
    
    func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
            //Iterate through any transactions which didn't come from a direct call to `purchase()`.
            for await result in Transaction.updates {
                do {
                    let transaction = try self.checkVerified(result)

                    //Deliver content to the user.
                    await self.updatePurchasedIdentifiers(transaction)

                    //Always finish a transaction.
                    await transaction.finish()
                } catch {
                    //StoreKit has a receipt it can read but it failed verification. Don't deliver content to the user.
                    print("Transaction failed verification")
                }
            }
        }
    }

}

public enum StoreError: Error {
    case failedVerification
    case purchaseFailed(result: Product.PurchaseResult)
    case purchaseFailed(error: Product.PurchaseError)
}
