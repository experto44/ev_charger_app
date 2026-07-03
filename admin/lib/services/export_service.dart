import 'dart:js_interop';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:intl/intl.dart';
import 'package:web/web.dart' as web;

import '../models/app_user.dart';

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
      ]);
    }

    final bytes = excel.save();
    if (bytes == null) return;
    final stamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
    _download(bytes, 'geocharge_users_$stamp.xlsx');
  }

  /// Save [bytes] to the user's machine via an object-URL anchor click.
  static void _download(List<int> bytes, String filename) {
    final data = Uint8List.fromList(bytes).toJS;
    final blob = web.Blob(
      <JSAny>[data].toJS,
      web.BlobPropertyBag(
        type:
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      ),
    );
    final url = web.URL.createObjectURL(blob);
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = filename
      ..style.display = 'none';
    web.document.body?.appendChild(anchor);
    anchor.click();
    anchor.remove();
    web.URL.revokeObjectURL(url);
  }
}
