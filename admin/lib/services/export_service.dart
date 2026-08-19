import 'package:excel/excel.dart';
import 'package:intl/intl.dart';

import '../models/app_user.dart';
import '../models/purchase.dart';
import 'browser.dart' as browser;
import 'finance_config.dart';

/// Builds an .xlsx workbook from a (already filtered) list of users and triggers
/// a browser download. Kept separate from the UI so the export logic is testable
/// and the columns live in one place.
class ExportService {
  static final DateFormat _fmt = DateFormat('yyyy-MM-dd HH:mm');

  /// Generate the spreadsheet for [users] and prompt the browser to save it.
  static void exportUsers(List<AppUser> users) {
    final excel = Excel.createExcel();
    const sheetName = 'Users';
    final Sheet sheet = excel[sheetName];
    excel.setDefaultSheet(sheetName);
    // Drop the auto-created default sheet so the file opens on our data.
    if (excel.sheets.containsKey('Sheet1')) {
      excel.delete('Sheet1');
    }

    sheet.appendRow([
      TextCellValue('Name'),
      TextCellValue('Phone'),
      TextCellValue('Email'),
      TextCellValue('Status'),
      TextCellValue('Platform'),
      TextCellValue('Registered'),
      TextCellValue('Last active'),
      TextCellValue('Opens/day'),
      TextCellValue('Total opens'),
      TextCellValue('Premium source'),
      TextCellValue('Premium until'),
      TextCellValue('Days left'),
      TextCellValue('Granted by'),
      TextCellValue('Note'),
    ]);

    for (final u in users) {
      sheet.appendRow([
        TextCellValue(u.name),
        TextCellValue(u.phone),
        TextCellValue(u.email),
        TextCellValue(u.statusLabel),
        TextCellValue(u.platform.isEmpty ? '—' : u.platform),
        TextCellValue(u.createdAt == null ? '' : _fmt.format(u.createdAt!)),
        TextCellValue(u.lastSeenAt == null ? '' : _fmt.format(u.lastSeenAt!)),
        TextCellValue(u.opensPerDay == null
            ? ''
            : u.opensPerDay!.toStringAsFixed(1)),
        IntCellValue(u.openCount),
        TextCellValue(u.isManual ? 'manual' : (u.isPremium ? 'store' : '')),
        TextCellValue(
            u.premiumUntil == null ? '' : _fmt.format(u.premiumUntil!)),
        TextCellValue(u.daysLeft == null ? '' : '${u.daysLeft}'),
        TextCellValue(u.premiumGrantedBy),
        TextCellValue(u.premiumNote),
      ]);
    }

    final bytes = excel.save();
    if (bytes == null) return;
    final stamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
    _download(bytes, 'geocharge_users_$stamp.xlsx');
  }

  /// Generate a spreadsheet of [purchases] (revenue events), with gross/net
  /// normalised to GEL using [cfg]'s commission + FX assumptions, and prompt a
  /// download. Mirrors the on-screen finance table so the export reconciles.
  static void exportPurchases(List<Purchase> purchases, FinanceConfig cfg) {
    final excel = Excel.createExcel();
    const sheetName = 'Purchases';
    final Sheet sheet = excel[sheetName];
    excel.setDefaultSheet(sheetName);
    if (excel.sheets.containsKey('Sheet1')) {
      excel.delete('Sheet1');
    }

    sheet.appendRow([
      TextCellValue('Date'),
      TextCellValue('User (uid)'),
      TextCellValue('Plan'),
      TextCellValue('Platform'),
      TextCellValue('Charged amount'),
      TextCellValue('Currency'),
      TextCellValue('Gross (GEL)'),
      TextCellValue('Commission (GEL)'),
      TextCellValue('Net (GEL)'),
      TextCellValue('Product id'),
    ]);

    for (final p in purchases) {
      final grossGel = cfg.toGel(p.gross, p.currency);
      final commission = grossGel * cfg.rateFor(p.platform);
      final netGel = grossGel - commission;
      sheet.appendRow([
        TextCellValue(p.createdAt == null ? '' : _fmt.format(p.createdAt!)),
        TextCellValue(p.uid),
        TextCellValue(p.planLabel),
        TextCellValue(p.platform),
        DoubleCellValue(p.gross),
        TextCellValue(p.currency),
        DoubleCellValue(double.parse(grossGel.toStringAsFixed(2))),
        DoubleCellValue(double.parse(commission.toStringAsFixed(2))),
        DoubleCellValue(double.parse(netGel.toStringAsFixed(2))),
        TextCellValue(p.productId),
      ]);
    }

    final bytes = excel.save();
    if (bytes == null) return;
    final stamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
    _download(bytes, 'geocharge_revenue_$stamp.xlsx');
  }

  /// Save [bytes] to the user's machine (browser download).
  static void _download(List<int> bytes, String filename) {
    browser.downloadBytes(
      bytes,
      filename,
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
  }
}
