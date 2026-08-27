import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:ev_charger_app/services/purchase_service.dart';

/// A transaction as the platform hands it to us. [token] stands in for the
/// StoreKit 2 `appAccountToken`; the base [PurchaseDetails] has no such field,
/// so the real one arrives on the iOS subclass and is read dynamically.
class _Tx extends PurchaseDetails {
  _Tx(PurchaseStatus status, {this.appAccountToken})
      : super(
          productID: PurchaseService.monthlyId,
          verificationData: PurchaseVerificationData(
            localVerificationData: '',
            serverVerificationData: '',
            source: 'app_store',
          ),
          transactionDate: '0',
          status: status,
        );

  final String? appAccountToken;
}

void main() {
  final svc = PurchaseService.I;
  const buyerUid = 'uid-of-the-person-who-paid';
  const freeloaderUid = 'uid-of-a-brand-new-account';

  group('a replayed store entitlement', () {
    test('does NOT grant premium to whatever account happens to be signed in',
        () {
      // The exact reported bug: an Apple ID owns the subscription, someone signs
      // into a fresh app account on that device, and StoreKit replays the
      // entitlement when the connection opens. Granting it here also wrote
      // isPremium:true to that account's Firestore doc, permanently.
      expect(
        svc.mayGrantTo(_Tx(PurchaseStatus.restored), freeloaderUid,
            restoreWasAsked: false, ownPurchaseFlow: false),
        isFalse,
      );
    });

    test('still grants when signed out — nothing to leak into, and this is a '
        'paying user\'s only way back (App Store 2.1(b))', () {
      expect(
        svc.mayGrantTo(_Tx(PurchaseStatus.restored), null,
            restoreWasAsked: false, ownPurchaseFlow: false),
        isTrue,
      );
    });

    test('grants when the transaction is stamped with this account', () {
      final mine = _Tx(PurchaseStatus.restored,
          appAccountToken: PurchaseService.accountTokenFor(buyerUid));
      expect(svc.mayGrantTo(mine, buyerUid, restoreWasAsked: false, ownPurchaseFlow: false), isTrue);
    });

    test('does not grant when the stamp belongs to a different account', () {
      final someoneElses = _Tx(PurchaseStatus.restored,
          appAccountToken: PurchaseService.accountTokenFor(buyerUid));
      expect(
        svc.mayGrantTo(someoneElses, freeloaderUid, restoreWasAsked: false, ownPurchaseFlow: false),
        isFalse,
      );
    });

    test('grants when the user deliberately tapped Restore purchases', () {
      expect(
        svc.mayGrantTo(_Tx(PurchaseStatus.restored), buyerUid,
            restoreWasAsked: true, ownPurchaseFlow: false),
        isTrue,
      );
    });
  });

  test('a purchase this app actually put through always grants', () {
    expect(
      svc.mayGrantTo(_Tx(PurchaseStatus.purchased), freeloaderUid,
          restoreWasAsked: false, ownPurchaseFlow: true),
      isTrue,
    );
  });

  test('a `purchased` event the app did not start is treated as a replay', () {
    // The path that actually caused the report. On StoreKit 2 the plugin
    // reports `.purchased` for everything arriving through Transaction.updates
    // — renewals, other devices, and the entitlements replayed when the
    // listener attaches on a fresh install. Only an explicit restorePurchases()
    // call ever produces `.restored`, so gating on the status alone would have
    // left this exact case wide open.
    expect(
      svc.mayGrantTo(_Tx(PurchaseStatus.purchased), freeloaderUid,
          restoreWasAsked: false, ownPurchaseFlow: false),
      isFalse,
    );
  });

  test('a renewal of a subscription this account bought still grants', () {
    final renewal = _Tx(PurchaseStatus.purchased,
        appAccountToken: PurchaseService.accountTokenFor(buyerUid));
    expect(
      svc.mayGrantTo(renewal, buyerUid,
          restoreWasAsked: false, ownPurchaseFlow: false),
      isTrue,
    );
  });

  group('the account token', () {
    test('is a stable RFC-4122 UUID, which StoreKit requires', () {
      final token = PurchaseService.accountTokenFor(buyerUid);
      expect(
        token,
        matches(RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
      );
      // Must be derivable again on another device, or a restore could never be
      // matched back to its buyer.
      expect(token, PurchaseService.accountTokenFor(buyerUid));
    });

    test('differs per account', () {
      expect(PurchaseService.accountTokenFor(buyerUid),
          isNot(PurchaseService.accountTokenFor(freeloaderUid)));
    });
  });
}
