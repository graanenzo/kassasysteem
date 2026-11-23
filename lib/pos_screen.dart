import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:printing/printing.dart';

import 'barcode_listener.dart';
import 'escpos.dart';
import 'invoice_api.dart';
import 'models.dart';
import 'numpad.dart';
import 'onscreen_keyboard.dart';
import 'plu_export.dart';
import 'plu_import.dart';
import 'product_store.dart';
import 'receipt.dart';
import 'settings.dart';
import 'sounds.dart';
import 'storage.dart';

/// The last paid sale, kept so it stays on screen after "Bon" / "Geen bon"
/// and can be reopened.
class _PaidSale {
  final int receiptNo;
  final DateTime time;
  final bool printed;
  final List<CartLine> lines;
  final int discountPercent;

  /// Set when the sale was given as an invoice (factuur).
  final String? invoiceNumber;

  /// Set when the sale was sent to the invoice program (customer name).
  final String? programCustomer;

  _PaidSale({
    required this.receiptNo,
    required this.time,
    required this.printed,
    required this.lines,
    required this.discountPercent,
    this.invoiceNumber,
    this.programCustomer,
  });

  SaleTotals get totals =>
      saleTotals(lines, discountPercent: discountPercent);
}

class PosScreen extends StatefulWidget {
  const PosScreen({super.key});

  @override
  State<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends State<PosScreen> {
  final store = ProductStore();
  Settings settings = Settings();
  final cart = <CartLine>[];
  final input = TextEditingController();
  final inputFocus = FocusNode();
  late final BarcodeListener scanner;

  List<Product> results = [];
  bool _showKeyboard = false;
  bool _soundOk = true;
  String? _errorCode;
  String? _errorRaw;
  Timer? _errorTimer;
  Timer? _labelTimer;
  Timer? _dayTimer;
  int todayTotal = 0;

  /// Day that [todayTotal] belongs to; the total starts again at 0 when the
  /// date changes, also when the app stays open overnight.
  DateTime _totalDay = DateTime.now();
  bool loading = true;
  DateTime _lastScanAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Staff discount on the whole sale; switched off again after each sale.
  static const staffDiscountPercent = 10;
  bool _staffDiscount = false;

  /// Last paid sale; can be reopened as long as no new customer has a
  /// product in the cart.
  _PaidSale? _lastSale;

  /// Whether [_lastSale] is still shown. Adding a product for the next
  /// customer hides it.
  bool _showLastSale = false;

  // An invoice has been given out with its own number, so that sale cannot
  // simply be reopened (it would need a credit invoice).
  bool get _canReopen =>
      _lastSale != null &&
      _lastSale!.invoiceNumber == null &&
      _lastSale!.programCustomer == null &&
      cart.isEmpty;

  int get _discountPercent => _staffDiscount ? staffDiscountPercent : 0;
  SaleTotals get totals => saleTotals(cart, discountPercent: _discountPercent);
  int get total => totals.total;

  @override
  void initState() {
    super.initState();
    scanner = BarcodeListener(
      onScan: _onScan,
      // Ignore scans while a dialog is open.
      isActive: () => mounted && (ModalRoute.of(context)?.isCurrent ?? true),
    );
    initSounds();
    _soundOk = soundsReady();
    _load();
  }

  Future<void> _load() async {
    await store.load();
    settings = await Settings.load();
    todayTotal = await SalesLog.todayTotal();
    _totalDay = DateTime.now();
    if (mounted) setState(() => loading = false);
    _dayTimer = Timer.periodic(
        const Duration(minutes: 1), (_) => _checkNewDay());
    _syncLabels(quiet: true);
    // New packagings in the sticker app show up during the day as well.
    _labelTimer = Timer.periodic(
        const Duration(minutes: 10), (_) => _syncLabels(quiet: true));
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Resets the day total after midnight.
  Future<void> _checkNewDay() async {
    final now = DateTime.now();
    if (_sameDay(now, _totalDay)) return;
    _totalDay = now;
    final fresh = await SalesLog.todayTotal();
    if (mounted) setState(() => todayTotal = fresh);
  }

  bool _syncing = false;

  /// Gets prices and EANs from the sticker app. At startup this runs quietly
  /// (offline the cached prices stay in use); from the button it reports.
  Future<void> _syncLabels({bool quiet = false}) async {
    if (_syncing || !mounted) return;
    setState(() => _syncing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final changed = await store.syncLabels();
      if (!quiet || changed > 0) {
        messenger.showSnackBar(SnackBar(
          content: Text('Productlijst: ${store.products.length} producten, '
              '$changed prijs${changed == 1 ? '' : 'zen'} bijgewerkt'),
        ));
      }
    } catch (e) {
      if (!quiet) {
        messenger.showSnackBar(SnackBar(
          content: Text('Productlijst niet bereikbaar: $e\n'
              'De laatst opgehaalde lijst blijft in gebruik.'),
          backgroundColor: Colors.red.shade700,
        ));
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  String get _labelsTooltip {
    final t = store.labelsFetchedAt;
    if (t == null) return 'Productlijst ophalen';
    String two(int n) => n.toString().padLeft(2, '0');
    return 'Productlijst ophalen (gebeurt ook elke 10 minuten)\n'
        'Laatst: ${two(t.day)}-${two(t.month)} ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  void dispose() {
    _errorTimer?.cancel();
    _labelTimer?.cancel();
    _dayTimer?.cancel();
    scanner.dispose();
    input.dispose();
    inputFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- scanning

  void _onScan(String code) {
    _lastScanAt = DateTime.now();
    input.clear();
    setState(() => results = []);
    final clean = code.trim();
    // QR codes and other non-numeric codes are never products.
    final numeric = RegExp(r'^\d+$').hasMatch(clean);
    final r = numeric ? resolveScan(clean, store) : null;
    if (r == null) {
      // An in-store sticker we don't know yet may be a packaging that was
      // just added in the sticker app: fetch it and try once more.
      if (numeric && clean.length == 13 && clean.startsWith('2')) {
        _retryAfterLabelSync(clean);
        return;
      }
      _notFound(clean.length > 30 ? '${clean.substring(0, 30)}…' : clean,
          raw: clean);
      return;
    }
    _addProduct(r.product,
        embeddedPriceCents: r.embeddedPriceCents,
        embeddedGrams: r.embeddedGrams);
  }

  Future<void> _retryAfterLabelSync(String code) async {
    try {
      await store.syncLabels();
    } catch (_) {
      // Offline: fall through to "not found".
    }
    if (!mounted) return;
    setState(() {});
    final r = resolveScan(code, store);
    if (r == null) {
      _notFound(code, raw: code);
    } else {
      _addProduct(r.product,
          embeddedPriceCents: r.embeddedPriceCents,
          embeddedGrams: r.embeddedGrams);
    }
  }

  void _onSubmit(String text) {
    // The scanner already handled this Enter.
    if (DateTime.now().difference(_lastScanAt).inMilliseconds < 300) return;
    final t = text.trim();
    if (t.isEmpty) return;

    if (RegExp(r'^\d+$').hasMatch(t)) {
      Product? p;
      ScanResult? r;
      if (t.length <= 5) {
        p = store.byPlu(int.parse(t)); // typed PLU number
      } else {
        r = resolveScan(t, store); // typed barcode
        p = r?.product;
      }
      _clearInput();
      if (p == null) {
        _notFound(t);
      } else {
        _addProduct(p,
            embeddedPriceCents: r?.embeddedPriceCents,
            embeddedGrams: r?.embeddedGrams);
      }
      return;
    }
    if (results.length == 1) {
      final p = results.first;
      _clearInput();
      _addProduct(p);
    }
  }

  void _onInputChanged(String text) {
    final t = text.trim();
    setState(() {
      results = (t.length >= 2 && !RegExp(r'^\d+$').hasMatch(t))
          ? store.search(t)
          : [];
    });
  }

  void _clearInput() {
    input.clear();
    setState(() => results = []);
    inputFocus.requestFocus();
  }

  void _unlockSound() {
    unlockSounds();
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted && _soundOk != soundsReady()) {
        setState(() => _soundOk = soundsReady());
      }
    });
  }

  void _notFound(String code, {String? raw}) {
    playError();
    _unlockSound();
    _errorTimer?.cancel();
    setState(() {
      _errorCode = code;
      _errorRaw = raw ?? code;
    });
    _errorTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _errorCode = null);
    });
    inputFocus.requestFocus();
  }

  void _clearError() {
    if (_errorCode == null) return;
    _errorTimer?.cancel();
    setState(() => _errorCode = null);
  }

  Future<void> _addProduct(Product p,
      {int? embeddedPriceCents, int? embeddedGrams}) async {
    _clearError(); // the scanner beeps itself on a good scan
    if (p.unit == SaleUnit.kg) {
      int? grams;
      int lineTotal;
      if (embeddedGrams != null) {
        // Label from the scale: the barcode holds the weight in grams.
        grams = embeddedGrams;
        lineTotal = (p.priceCents * grams / 1000).round();
      } else {
        grams = await _askGrams(p);
        if (grams == null) return;
        lineTotal = (p.priceCents * grams / 1000).round();
      }
      setState(() {
        _showLastSale = false; // the next customer starts
        cart.add(CartLine(product: p, unitPriceCents: lineTotal, grams: grams));
      });
    } else {
      // A sticker with a price in the barcode: the price on the sticker counts.
      final price = embeddedPriceCents ?? p.priceCents;
      setState(() {
        _showLastSale = false; // the next customer starts
        final i = cart.indexWhere((l) =>
            l.product.plu == p.plu &&
            l.grams == null &&
            l.unitPriceCents == price);
        if (i >= 0) {
          final line = cart.removeAt(i);
          line.quantity++;
          cart.add(line);
        } else {
          cart.add(CartLine(product: p, unitPriceCents: price));
        }
      });
    }
    inputFocus.requestFocus();
  }

  /// Adds a product that is not in the PLU list. With "save" checked it is
  /// remembered (with its barcode, if given) for next time.
  Future<void> _addOwnProduct({String? ean}) async {
    _clearError();
    final name = TextEditingController();
    final price = TextEditingController();
    final code = TextEditingController(
        text: (ean != null && RegExp(r'^\d+$').hasMatch(ean)) ? ean : '');
    var save = code.text.isNotEmpty;
    // Which on-screen keys are shown: 'name' (letters), 'price' (numbers)
    // or 'none'.
    var pad = 'price';
    final result = await showDialog<Product>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final cents = parseEuro(price.text);
        final valid = cents != null && cents > 0;
        Product build() => Product(
              plu: store.nextCustomPlu(),
              name: name.text.trim().isEmpty ? 'Diversen' : name.text.trim(),
              unit: SaleUnit.piece,
              priceCents: cents!,
              ean: code.text.replaceAll(RegExp(r'\D'), ''),
            );
        return AlertDialog(
          scrollable: true,
          title: const Text('Eigen product'),
          content: SizedBox(
            width: pad == 'name' ? 640 : 400,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: name,
                autofocus: true,
                keyboardType: TextInputType.none, // ingebouwd toetsenbord, niet dat van de iPad
                onTap: () => setD(() => pad = 'name'),
                decoration: InputDecoration(
                  labelText: 'Naam',
                  hintText: 'bijv. Diversen',
                  suffixIcon: IconButton(
                    tooltip: 'Toetsenbord',
                    icon: Icon(pad == 'name'
                        ? Icons.keyboard_hide
                        : Icons.keyboard_alt_outlined),
                    onPressed: () =>
                        setD(() => pad = pad == 'name' ? 'none' : 'name'),
                  ),
                ),
              ),
              TextField(
                controller: price,
                onTap: () => setD(() => pad = 'price'),
                keyboardType: TextInputType.none, // ingebouwd toetsenbord, niet dat van de iPad

                decoration: InputDecoration(
                  labelText: 'Prijs',
                  prefixText: '€ ',
                  suffixIcon: IconButton(
                    tooltip: 'Cijfers',
                    icon: const Icon(Icons.dialpad),
                    onPressed: () =>
                        setD(() => pad = pad == 'price' ? 'none' : 'price'),
                  ),
                ),
                onChanged: (_) => setD(() {}),
                onSubmitted: (_) {
                  if (valid) Navigator.pop(ctx, build());
                },
              ),
              const SizedBox(height: 8),
              if (pad == 'name')
                OnScreenKeyboard(
                  controller: name,
                  onChanged: () => setD(() {}),
                  onEnter: () => setD(() => pad = 'price'),
                  onClose: () => setD(() => pad = 'none'),
                ),
              if (pad == 'price')
                NumPad(
                  controller: price,
                  decimal: true,
                  keyHeight: 44,
                  onChanged: () => setD(() {}),
                ),
              TextField(
                controller: code,
                keyboardType: TextInputType.none, // ingebouwd toetsenbord, niet dat van de iPad

                decoration: const InputDecoration(
                    labelText: 'Barcode (optioneel, je kunt hier scannen)'),
                onChanged: (v) => setD(() {
                  if (v.trim().isNotEmpty) save = true;
                }),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: save,
                onChanged: (v) => setD(() => save = v ?? false),
                title: const Text('Bewaren in productlijst'),
                subtitle: const Text(
                    'Dan wordt hij de volgende keer herkend bij scannen'),
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Annuleren')),
            FilledButton(
              onPressed: valid ? () => Navigator.pop(ctx, build()) : null,
              child: const Text('Toevoegen'),
            ),
          ],
        );
      }),
    );
    if (result == null) {
      inputFocus.requestFocus();
      return;
    }
    if (save) {
      // Meteen in de database, zodat hij op alle kassa's bekend is.
      final saved = await store.addToDatabase(result,
          till: kIsWeb ? 'iPad (web)' : 'laptop');
      if (mounted) setState(() {});
      await _addProduct(saved);
    } else {
      await _addProduct(result);
    }
  }

  Future<int?> _askGrams(Product p) async {
    final c = TextEditingController();
    final grams = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(p.displayName),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('${euro(p.priceCents)} per kg'),
          const SizedBox(height: 12),
          TextField(
            controller: c,
            autofocus: true,
            keyboardType: TextInputType.none, // ingebouwd toetsenbord, niet dat van de iPad

            decoration: const InputDecoration(
                labelText: 'Gewicht', suffixText: 'gram'),
            onSubmitted: (v) => Navigator.pop(ctx, int.tryParse(v.trim())),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: 300,
            child: NumPad(
              controller: c,
              onEnter: () => Navigator.pop(ctx, int.tryParse(c.text.trim())),
              enterLabel: 'Toevoegen',
            ),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annuleren')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, int.tryParse(c.text.trim())),
              child: const Text('Toevoegen')),
        ],
      ),
    );
    return (grams != null && grams > 0) ? grams : null;
  }

  // ---------------------------------------------------------------- checkout

  Future<void> _checkout(
      {required bool printBon,
      InvoiceInfo? invoice,
      String? programCustomer}) async {
    if (cart.isEmpty) return;
    final lines = List<CartLine>.of(cart);
    final sum = total;
    final discountPercent = _discountPercent;
    final now = DateTime.now();
    final no = settings.nextReceiptNo;
    settings.nextReceiptNo++;
    await settings.save();
    await SalesLog.append(
        receiptNo: no,
        time: now,
        method: programCustomer != null
            ? 'factuurprogramma'
            : invoice != null
                ? 'factuur'
                : (printBon ? 'bon' : 'geen bon'),
        lines: lines,
        discountPercent: discountPercent,
        invoiceNumber: invoice?.number);
    if (!_sameDay(now, _totalDay)) {
      _totalDay = now;
      todayTotal = 0;
    }
    setState(() {
      // The paid sale stays on screen until the next product is scanned.
      _lastSale = _PaidSale(
          receiptNo: no,
          time: now,
          printed: printBon,
          lines: lines,
          discountPercent: discountPercent,
          invoiceNumber: invoice?.number,
          programCustomer: programCustomer);
      _showLastSale = true;
      cart.clear();
      _staffDiscount = false;
      todayTotal += sum;
    });
    if (printBon) {
      try {
        if (settings.printerIp.trim().isNotEmpty) {
          await sendToNetworkPrinter(
            settings.printerIp,
            buildEscPosReceipt(
                settings: settings,
                lines: lines,
                receiptNo: no,
                time: now,
                logo: await loadLogo(),
                discountPercent: discountPercent,
                invoice: invoice),
          );
        } else {
          final pdf = await buildReceipt(
              settings: settings,
              lines: lines,
              receiptNo: no,
              time: now,
              discountPercent: discountPercent,
              invoice: invoice);
          await printReceipt(pdf, settings);
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(invoice != null
                ? 'Factuur ${invoice.number} printen mislukt: $e'
                : 'Bon printen mislukt: $e'),
            backgroundColor: Colors.red.shade700,
          ));
        }
      }
    }
    inputFocus.requestFocus();
  }

  /// One "Factuur" button: choose between printing an invoice on the
  /// receipt printer and sending the sale to the invoice program.
  Future<void> _invoiceMenu() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Factuur (${euro(total)})'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'print'),
            child: const ListTile(
              leading: Icon(Icons.print),
              title: Text('Bonfactuur printen'),
              subtitle: Text('Factuur met nummer direct op de bonprinter'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'program'),
            child: const ListTile(
              leading: Icon(Icons.send),
              title: Text('Naar factuurprogramma'),
              subtitle: Text('Bestaande klant; de factuur komt in To do'),
            ),
          ),
        ],
      ),
    );
    if (choice == 'print') {
      await _invoiceCheckout();
    } else if (choice == 'program') {
      await _programCheckout();
    } else {
      inputFocus.requestFocus();
    }
  }

  /// Asks the customer details, gets an invoice number from Supabase and
  /// prints the sale as an invoice on the receipt printer.
  Future<void> _invoiceCheckout() async {
    if (cart.isEmpty) return;
    final name = TextEditingController();
    final address = TextEditingController();
    final vat = TextEditingController();
    var paid = true;
    TextEditingController? keys = name;
    String? error;
    var busy = false;
    final info = await showDialog<InvoiceInfo>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        Future<void> submit() async {
          if (name.text.trim().isEmpty) {
            setD(() => error = 'Vul de naam van de klant in');
            return;
          }
          setD(() {
            busy = true;
            error = null;
          });
          try {
            final number = await createInvoice(
              lines: List<CartLine>.of(cart),
              discountPercent: _discountPercent,
              receiptNo: settings.nextReceiptNo,
              customerName: name.text.trim(),
              customerAddress: address.text.trim(),
              customerVat: vat.text.trim(),
              paid: paid,
            );
            if (ctx.mounted) {
              Navigator.pop(
                  ctx,
                  InvoiceInfo(
                    number: number,
                    customerName: name.text.trim(),
                    customerAddress: address.text.trim(),
                    customerVat: vat.text.trim(),
                    paid: paid,
                  ));
            }
          } catch (e) {
            setD(() {
              busy = false;
              error = e.toString().replaceFirst('Exception: ', '');
            });
          }
        }

        Widget field(TextEditingController c, String label,
                {int lines = 1, String? hint}) =>
            TextField(
              controller: c,
              maxLines: lines,
              keyboardType: TextInputType.none, // ingebouwd toetsenbord, niet dat van de iPad
              onTap: () => setD(() => keys = c),
              decoration: InputDecoration(labelText: label, hintText: hint),
            );
        return AlertDialog(
          scrollable: true,
          title: Text('Bonfactuur (${euro(total)})'),
          content: SizedBox(
            width: keys != null ? 640 : 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              field(name, 'Naam klant / bedrijf *'),
              field(address, 'Adres', lines: 2, hint: 'Straat en nummer\nPostcode en plaats'),
              field(vat, 'Btw-nummer klant (optioneel)'),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Betaald'), icon: Icon(Icons.check)),
                  ButtonSegment(value: false, label: Text('Op rekening'), icon: Icon(Icons.schedule)),
                ],
                selected: {paid},
                onSelectionChanged: (v) => setD(() => paid = v.first),
              ),
              if (!paid)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                      'Op de factuur komt: binnen ${settings.paymentDays} dagen '
                      'overmaken op ${settings.iban}.',
                      style: Theme.of(ctx).textTheme.bodySmall),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(error!,
                      style: TextStyle(color: Colors.red.shade700)),
                ),
              const SizedBox(height: 8),
              if (keys != null)
                OnScreenKeyboard(
                  controller: keys!,
                  onChanged: () => setD(() {}),
                  onEnter: () => setD(() => keys = keys == name
                      ? address
                      : keys == address
                          ? vat
                          : null),
                  onClose: () => setD(() => keys = null),
                ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: busy ? null : () => Navigator.pop(ctx),
                child: const Text('Annuleren')),
            FilledButton.icon(
              onPressed: busy ? null : submit,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.print),
              label: const Text('Factuur printen'),
            ),
          ],
        );
      }),
    );
    if (info == null) {
      inputFocus.requestFocus();
      return;
    }
    await _checkout(printBon: true, invoice: info);
  }

  /// Sends the sale to the "To do" of the invoice program for an existing
  /// customer. The invoice gets its number there; nothing is printed here.
  Future<void> _programCheckout() async {
    if (cart.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    List<InvoiceCustomer> customers;
    try {
      customers = await fetchInvoiceCustomers();
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Klanten ophalen mislukt: ${e.toString().replaceFirst('Exception: ', '')}'),
        backgroundColor: Colors.red.shade700,
      ));
      return;
    }
    if (!mounted) return;
    final search = TextEditingController();
    InvoiceCustomer? chosen;
    var showKeys = true;
    var busy = false;
    String? error;
    final sent = await showDialog<InvoiceCustomer>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final q = search.text.trim().toLowerCase();
        final list = q.isEmpty
            ? customers
            : customers
                .where((c) => '${c.name} ${c.town}'.toLowerCase().contains(q))
                .toList();
        Future<void> send() async {
          final c = chosen;
          if (c == null) return;
          setD(() {
            busy = true;
            error = null;
          });
          try {
            await sendToInvoiceProgram(
              customer: c,
              lines: List<CartLine>.of(cart),
              discountPercent: _discountPercent,
              receiptNo: settings.nextReceiptNo,
            );
            if (ctx.mounted) Navigator.pop(ctx, c);
          } catch (e) {
            setD(() {
              busy = false;
              error = e.toString().replaceFirst('Exception: ', '');
            });
          }
        }

        return AlertDialog(
          title: Text('Naar factuurprogramma (${euro(total)})'),
          content: SizedBox(
            width: showKeys ? 640 : 460,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: search,
                autofocus: true,
                keyboardType: TextInputType.none, // ingebouwd toetsenbord, niet dat van de iPad
                onChanged: (_) => setD(() {}),
                onTap: () => setD(() => showKeys = true),
                decoration: const InputDecoration(
                    labelText: 'Zoek klant',
                    prefixIcon: Icon(Icons.search)),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 240,
                child: list.isEmpty
                    ? const Center(
                        child: Text('Geen klant gevonden. Nieuwe klanten '
                            'voeg je toe in het factuurprogramma.'))
                    : ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (_, i) {
                          final c = list[i];
                          return ListTile(
                            dense: true,
                            selected: chosen?.id == c.id,
                            selectedTileColor:
                                Theme.of(ctx).colorScheme.primaryContainer,
                            title: Text(c.name),
                            subtitle: c.town.isEmpty ? null : Text(c.town),
                            onTap: () => setD(() => chosen = c),
                          );
                        },
                      ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(error!,
                      style: TextStyle(color: Colors.red.shade700)),
                ),
              if (showKeys)
                OnScreenKeyboard(
                  controller: search,
                  onChanged: () => setD(() {}),
                  onEnter: () => setD(() {
                    if (list.length == 1) chosen = list.first;
                    showKeys = false;
                  }),
                  onClose: () => setD(() => showKeys = false),
                ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: busy ? null : () => Navigator.pop(ctx),
                child: const Text('Annuleren')),
            FilledButton.icon(
              onPressed: busy || chosen == null ? null : send,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: Text(chosen == null
                  ? 'Kies een klant'
                  : 'Versturen naar ${chosen!.name}'),
            ),
          ],
        );
      }),
    );
    if (sent == null) {
      inputFocus.requestFocus();
      return;
    }
    await _checkout(printBon: false, programCustomer: sent.name);
    messenger.showSnackBar(SnackBar(
        content: Text('Staat in To do van het factuurprogramma: ${sent.name}')));
  }

  /// Puts the last paid sale back in the cart so it can be corrected and
  /// paid again. The old sale no longer counts in the day total.
  Future<void> _reopenLastSale() async {
    final sale = _lastSale;
    if (sale == null || cart.isNotEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Vorige klant heropenen?'),
        content: Text('Bon ${sale.receiptNo} (${euro(sale.totals.total)}) '
            'komt terug in de kassa en telt niet meer mee in de dagomzet. '
            'Reken daarna opnieuw af met "Bon" of "Geen bon".'
            '${sale.printed ? '\n\nDe al geprinte bon is dan niet meer '
                'geldig.' : ''}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuleren')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Heropenen')),
        ],
      ),
    );
    if (ok != true || !mounted || cart.isNotEmpty) {
      inputFocus.requestFocus();
      return;
    }
    await SalesLog.markReopened(sale.receiptNo);
    if (!mounted) return;
    setState(() {
      cart
        ..clear()
        ..addAll(sale.lines);
      _staffDiscount = sale.discountPercent > 0;
      if (_sameDay(sale.time, _totalDay)) {
        todayTotal -= sale.totals.total;
      }
      _lastSale = null;
      _showLastSale = false;
    });
    inputFocus.requestFocus();
  }

  // ------------------------------------------------------- import & settings

  Future<void> _import() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Kies PLU-bestand (CSV of Excel)',
      type: FileType.custom,
      allowedExtensions: ['csv', 'CSV', 'xlsx', 'txt'],
      withData: true,
    );
    if (picked == null) return;
    final f = picked.files.single;
    try {
      final bytes = f.bytes ?? await readPickedPath(f.path!);
      final r = importPluFile(bytes, f.name);
      if (r.products.isEmpty) {
        throw const FormatException('geen producten gevonden');
      }
      await store.replaceImported(r.products);
      if (!mounted) return;
      setState(() {});
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('PLU ingelezen'),
          content: Text('${r.products.length} producten\n'
              '${r.withEan} met EAN-code\n'
              '${r.weighed} per kg (weegartikelen)\n'
              '${store.duplicateEans} dubbele EAN-codes '
              '(eerste product telt)\n'
              '${r.skippedRows} regels overgeslagen'),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Inlezen mislukt: $e')));
    }
  }

  Future<void> _export() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = exportPluXlsx(store.products);
      final saved = await saveFileAs(pluExportFileName(DateTime.now()), bytes);
      if (saved != null) {
        messenger.showSnackBar(SnackBar(
          content: Text('${store.products.length} producten geëxporteerd naar '
              '$saved. Pas de prijzen aan in Excel en lees het bestand '
              'daarna weer in met "PLU inlezen".'),
          duration: const Duration(seconds: 8),
        ));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Exporteren mislukt: $e'),
        backgroundColor: Colors.red.shade700,
      ));
    }
    inputFocus.requestFocus();
  }

  Future<void> _editSettings() async {
    final name = TextEditingController(text: settings.shopName);
    final addr = TextEditingController(text: settings.address);
    final foot = TextEditingController(text: settings.footer);
    final ip = TextEditingController(text: settings.printerIp);
    final invName = TextEditingController(text: settings.invoiceName);
    final invAddr = TextEditingController(text: settings.invoiceAddress);
    final invVat = TextEditingController(text: settings.vatNumber);
    final invKvk = TextEditingController(text: settings.kvkNumber);
    final invIban = TextEditingController(text: settings.iban);
    final invDays =
        TextEditingController(text: settings.paymentDays.toString());
    final width =
        TextEditingController(text: settings.receiptWidth.toString());
    String testStatus = '';
    var hasLogo = await readBytes('logo.png') != null;
    if (!mounted) return;
    String? printerUrl = settings.printerUrl;
    String? printerName = settings.printerName;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          scrollable: true,
          title: const Text('Instellingen'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Winkelnaam')),
              TextField(
                  controller: addr,
                  maxLines: 3,
                  decoration: const InputDecoration(
                      labelText: 'Adres / KvK / telefoon (op de bon)')),
              TextField(
                  controller: foot,
                  decoration:
                      const InputDecoration(labelText: 'Tekst onderaan bon')),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Op de factuur',
                    style: Theme.of(ctx).textTheme.titleSmall),
              ),
              TextField(
                  controller: invName,
                  decoration: const InputDecoration(labelText: 'Bedrijfsnaam')),
              TextField(
                  controller: invAddr,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Adres')),
              Row(children: [
                Expanded(
                    child: TextField(
                        controller: invVat,
                        decoration:
                            const InputDecoration(labelText: 'Btw-nummer'))),
                const SizedBox(width: 12),
                Expanded(
                    child: TextField(
                        controller: invKvk,
                        decoration:
                            const InputDecoration(labelText: 'KvK-nummer'))),
              ]),
              Row(children: [
                Expanded(
                    flex: 3,
                    child: TextField(
                        controller: invIban,
                        decoration: const InputDecoration(labelText: 'IBAN'))),
                const SizedBox(width: 12),
                Expanded(
                    child: TextField(
                        controller: invDays,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            labelText: 'Betalen binnen (dagen)'))),
              ]),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: ip,
                    decoration: const InputDecoration(
                        labelText: 'IP-adres bonprinter (Epson netwerk)',
                        hintText: 'bijv. 192.168.1.50'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: width,
                    keyboardType: TextInputType.number,
                    decoration:
                        const InputDecoration(labelText: 'Tekens/regel'),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                OutlinedButton(
                  onPressed: () async {
                    final t = Settings(
                      shopName: name.text.trim(),
                      receiptWidth:
                          int.tryParse(width.text.trim()) ?? 33,
                    );
                    setD(() => testStatus = 'Bezig...');
                    try {
                      await sendToNetworkPrinter(ip.text,
                          buildEscPosTest(t, logo: await loadLogo()));
                      setD(() => testStatus = 'Testbon verstuurd');
                    } catch (e) {
                      setD(() => testStatus = 'Mislukt: $e');
                    }
                  },
                  child: const Text('Testbon'),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(testStatus)),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                    child: Text(hasLogo
                        ? 'Logo op de bon: ingesteld'
                        : 'Logo op de bon: standaard')),
                TextButton(
                  onPressed: () async {
                    final picked = await FilePicker.platform.pickFiles(
                      dialogTitle: 'Kies logo (PNG of JPG)',
                      type: FileType.image,
                      withData: true,
                    );
                    if (picked == null) return;
                    final f = picked.files.single;
                    final bytes =
                        f.bytes ?? await readPickedPath(f.path!);
                    final ok = await saveLogo(bytes);
                    setD(() {
                      hasLogo = ok || hasLogo;
                      testStatus = ok
                          ? 'Logo opgeslagen, maak een testbon'
                          : 'Dit bestand kan niet als logo gebruikt worden';
                    });
                  },
                  child: const Text('Kies logo'),
                ),
                if (hasLogo)
                  IconButton(
                    tooltip: 'Logo verwijderen',
                    icon: const Icon(Icons.clear),
                    onPressed: () async {
                      await removeLogo();
                      setD(() => hasLogo = false);
                    },
                  ),
              ]),
              if (!kIsWeb) ...[
                const SizedBox(height: 16),
              Row(children: [
                Expanded(
                    child: Text(
                        'Of Windows-printer: ${printerName ?? 'geen'}')),
                TextButton(
                  onPressed: () async {
                    final p = await Printing.pickPrinter(context: ctx);
                    if (p != null) {
                      setD(() {
                        printerUrl = p.url;
                        printerName = p.name;
                      });
                    }
                  },
                  child: const Text('Kies printer'),
                ),
                if (printerUrl != null)
                  IconButton(
                    tooltip: 'Wissen',
                    icon: const Icon(Icons.clear),
                    onPressed: () => setD(() {
                      printerUrl = null;
                      printerName = null;
                    }),
                  ),
              ]),
              ],
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Annuleren')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Opslaan')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    settings
      ..shopName = name.text.trim()
      ..address = addr.text
      ..footer = foot.text
      ..printerUrl = printerUrl
      ..printerName = printerName
      ..printerIp = ip.text.trim()
      ..receiptWidth = int.tryParse(width.text.trim()) ?? 33
      ..invoiceName = invName.text.trim()
      ..invoiceAddress = invAddr.text.trim()
      ..vatNumber = invVat.text.trim()
      ..kvkNumber = invKvk.text.trim()
      ..iban = invIban.text.trim()
      ..paymentDays = int.tryParse(invDays.text.trim()) ?? 7;
    await settings.save();
    inputFocus.requestFocus();
  }

  // -------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Listener(
      onPointerDown: (_) => _unlockSound(),
      child: Scaffold(
      appBar: AppBar(
        toolbarHeight: 64,
        title: Image.asset('assets/logo.png', height: 46),
        actions: [
          Center(child: Text('Vandaag: ${euro(todayTotal)}')),
          const SizedBox(width: 16),
          if (store.cloud == null)
            TextButton.icon(
              onPressed: _import,
              icon: const Icon(Icons.upload_file),
              label: Text('PLU inlezen (${store.products.length})'),
            )
          else
            Center(child: Text('${store.products.length} producten')),
          IconButton(
            tooltip: _labelsTooltip,
            onPressed: _syncing ? null : () => _syncLabels(),
            icon: _syncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
          ),
          TextButton.icon(
            onPressed: store.products.isEmpty ? null : _export,
            icon: const Icon(Icons.download),
            label: const Text('PLU exporteren'),
          ),
          IconButton(
            tooltip: 'Instellingen',
            onPressed: _editSettings,
            icon: const Icon(Icons.settings),
          ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: _showKeyboard
          ? OnScreenKeyboard(
              controller: input,
              onChanged: () => _onInputChanged(input.text),
              onEnter: () => _onSubmit(input.text),
              onClose: () => setState(() => _showKeyboard = false),
            )
          : null,
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              if (!_soundOk)
                Material(
                  color: const Color(0xFF1A1A1A),
                  child: InkWell(
                    onTap: _unlockSound,
                    child: const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Row(children: [
                        Icon(Icons.volume_off, color: Colors.white),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Geluid staat nog uit. Tik hier om het aan te '
                            'zetten, en controleer het volume van de iPad.',
                            style: TextStyle(color: Colors.white, fontSize: 16),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
              Expanded(
              child: Row(children: [
              Expanded(
                child: Stack(children: [
                  Positioned.fill(
                    child: Image.asset('assets/background.jpg',
                        fit: BoxFit.cover),
                  ),
                  Positioned.fill(child: _cartView(theme)),
                  if (_errorCode != null)
                    Positioned(
                      left: 16,
                      right: 16,
                      top: 16,
                      child: GestureDetector(
                        onTap: _clearError,
                        child: Material(
                          elevation: 6,
                          borderRadius: BorderRadius.circular(12),
                          color: Colors.red.shade700,
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Row(children: [
                              const Icon(Icons.error_outline,
                                  color: Colors.white, size: 40),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text('Niet herkend',
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 24,
                                            fontWeight: FontWeight.bold)),
                                    Text(
                                        'Code $_errorCode staat niet in de '
                                        'PLU-lijst. Scan opnieuw of zoek het '
                                        'product op.',
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 16)),
                                  ],
                                ),
                              ),
                              if (RegExp(r'^\d+$')
                                  .hasMatch(_errorRaw ?? ''))
                                FilledButton(
                                  style: FilledButton.styleFrom(
                                      backgroundColor: Colors.white,
                                      foregroundColor: Colors.red.shade700),
                                  onPressed: () =>
                                      _addOwnProduct(ean: _errorRaw),
                                  child: const Text('Toevoegen'),
                                ),
                            ]),
                          ),
                        ),
                      ),
                    ),
                ]),
              ),
              const VerticalDivider(width: 1),
              ColoredBox(
                color: Colors.white,
                child: SizedBox(width: 380, child: _sidePanel(theme)),
              ),
            ]),
              ),
            ]),
      ),
    );
  }

  Widget _cartView(ThemeData theme) {
    if (store.products.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Nog geen producten.'),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => _syncLabels(),
            icon: const Icon(Icons.sync),
            label: const Text('Productlijst ophalen'),
          ),
        ]),
      );
    }
    final last = _lastSale;
    if (cart.isEmpty && _showLastSale && last != null) {
      return Container(
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xE6FFFFFF),
          borderRadius: BorderRadius.circular(16),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            color: Colors.green.shade700,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(children: [
              const Icon(Icons.check_circle, color: Colors.white, size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                        'Afgerekend: ${euro(last.totals.total)}'
                        '  ·  ${last.programCustomer != null ? 'naar factuurprogramma (${last.programCustomer})' : last.invoiceNumber != null ? 'bonfactuur ${last.invoiceNumber}' : last.printed ? 'bon' : 'geen bon'}'
                        '  ·  nr. ${last.receiptNo}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold)),
                    const Text('Scan een product voor de volgende klant',
                        style: TextStyle(color: Colors.white, fontSize: 15)),
                  ],
                ),
              ),
            ]),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(8),
              itemCount: last.lines.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final l = last.lines[i];
                return ListTile(
                  title: Text(l.product.displayName),
                  subtitle: Text('PLU ${l.product.plu}  ·  ${lineDetail(l)}'),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('${l.quantity}×'),
                    SizedBox(
                      width: 90,
                      child: Text(euro(l.totalCents),
                          textAlign: TextAlign.right,
                          style: theme.textTheme.titleMedium),
                    ),
                  ]),
                );
              },
            ),
          ),
        ]),
      );
    }
    if (cart.isEmpty) {
      return Center(
        child: Container(
          padding: const EdgeInsets.fromLTRB(40, 32, 40, 28),
          decoration: BoxDecoration(
            color: const Color(0xCCFFFFFF),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Image.asset('assets/logo.png', width: 280),
            const SizedBox(height: 24),
            Text('Scan een product', style: theme.textTheme.headlineSmall),
          ]),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xE6FFFFFF),
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: _cartList(theme),
    );
  }

  Widget _cartList(ThemeData theme) {
    return ListView.separated(
      padding: const EdgeInsets.all(8),
      itemCount: cart.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final l = cart[i];
        return ListTile(
          title: Text(l.product.displayName),
          subtitle: Text('PLU ${l.product.plu}  ·  ${lineDetail(l)}'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              icon: const Icon(Icons.remove),
              onPressed: () => setState(() {
                if (l.quantity > 1) {
                  l.quantity--;
                } else {
                  cart.removeAt(i);
                }
              }),
            ),
            Text('${l.quantity}'),
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: () => setState(() => l.quantity++),
            ),
            SizedBox(
              width: 90,
              child: Text(euro(l.totalCents),
                  textAlign: TextAlign.right,
                  style: theme.textTheme.titleMedium),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => setState(() => cart.removeAt(i)),
            ),
          ]),
        );
      },
    );
  }

  Widget _sidePanel(ThemeData theme) {
    final searching = _showKeyboard || results.isNotEmpty;
    // Right after paying, the paid sale's amounts stay visible.
    final paid = (cart.isEmpty && _showLastSale) ? _lastSale : null;
    final shown = paid?.totals ?? totals;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: input,
          focusNode: inputFocus,
          autofocus: true,
          keyboardType: TextInputType.none, // ingebouwd toetsenbord, niet dat van de iPad
          decoration: InputDecoration(
            labelText: 'PLU-nummer, EAN of zoeken',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.search),
            suffixIcon: IconButton(
              tooltip: 'Toetsenbord',
              icon: Icon(_showKeyboard
                  ? Icons.keyboard_hide
                  : Icons.keyboard_alt_outlined),
              onPressed: () =>
                  setState(() => _showKeyboard = !_showKeyboard),
            ),
          ),
          onChanged: _onInputChanged,
          onSubmitted: _onSubmit,
        ),
        const SizedBox(height: 8),
        // Direct onder de zoekbalk: een product dat niet gevonden wordt,
        // voeg je hier met een eigen prijs toe.
        SizedBox(
          height: 52,
          child: FilledButton.tonalIcon(
            onPressed: () => _addOwnProduct(),
            icon: const Icon(Icons.add),
            label: const Text('Eigen product / prijs',
                style: TextStyle(fontSize: 18)),
          ),
        ),
        Expanded(
          child: ListView(children: [
            for (final p in results)
              ListTile(
                dense: true,
                title: Text(p.displayName),
                subtitle: Text('PLU ${p.plu}'
                    '${p.ean.isNotEmpty ? '  ·  ${p.ean}' : ''}'),
                trailing: Text(p.unit == SaleUnit.kg
                    ? '${euro(p.priceCents)}/kg'
                    : euro(p.priceCents)),
                onTap: () {
                  setState(() => _showKeyboard = false);
                  _clearInput();
                  _addProduct(p);
                },
              ),
          ]),
        ),
        // While searching, the results get the space; totals and pay
        // buttons come back once a product is picked.
        if (!searching) ...[
        const Divider(),
        if (shown.discount > 0) ...[
          Row(children: [
            const Text('Subtotaal'),
            const Spacer(),
            Text(euro(shown.subtotal)),
          ]),
          Row(children: [
            Text('Personeelskorting ${shown.discountPercent}%'),
            const Spacer(),
            Text(euro(-shown.discount)),
          ]),
          const SizedBox(height: 4),
        ],
        Row(children: [
          Text(paid != null ? 'Betaald' : 'Totaal',
              style: theme.textTheme.headlineSmall),
          const Spacer(),
          Text(euro(shown.total), style: theme.textTheme.headlineMedium),
        ]),
        const SizedBox(height: 16),
        SizedBox(
          height: 64,
          child: FilledButton.icon(
            onPressed: cart.isEmpty ? null : () => _checkout(printBon: true),
            icon: const Icon(Icons.receipt_long),
            label: const Text('Bon', style: TextStyle(fontSize: 20)),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 64,
          child: FilledButton.tonalIcon(
            onPressed: cart.isEmpty ? null : () => _checkout(printBon: false),
            icon: const Icon(Icons.check),
            label: const Text('Geen bon', style: TextStyle(fontSize: 20)),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 48,
          child: OutlinedButton.icon(
            onPressed: cart.isEmpty ? null : _invoiceMenu,
            icon: const Icon(Icons.description_outlined),
            label: const Text('Factuur', style: TextStyle(fontSize: 18)),
          ),
        ),
        if (_canReopen) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _reopenLastSale,
            icon: const Icon(Icons.undo),
            label: Text('Vorige klant heropenen '
                '(${euro(_lastSale!.totals.total)})'),
          ),
        ],
        const SizedBox(height: 8),
        _staffDiscount
            ? FilledButton.tonalIcon(
                onPressed: () => setState(() => _staffDiscount = false),
                icon: const Icon(Icons.check_box),
                label: Text('Personeelskorting $staffDiscountPercent% (aan)'),
              )
            : OutlinedButton.icon(
                onPressed: () => setState(() => _staffDiscount = true),
                icon: const Icon(Icons.check_box_outline_blank),
                label: Text('Personeelskorting $staffDiscountPercent%'),
              ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: (cart.isEmpty && paid == null)
              ? null
              : () => setState(() {
                    cart.clear();
                    _staffDiscount = false;
                    _showLastSale = false;
                  }),
          child: const Text('Leegmaken'),
        ),
        ],
      ]),
    );
  }
}
