import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'places_service.dart';

class PlaceAutocompleteField extends StatefulWidget {
  final String label;
  final PlacesService places;
  final TextEditingController controller;

  /// NUEVO: incluye sessionToken
  final void Function(String description, String placeId, String sessionToken) onSelected;

  final bool enabled;

  final double? biasLat;
  final double? biasLng;

  const PlaceAutocompleteField({
    super.key,
    required this.label,
    required this.places,
    required this.controller,
    required this.onSelected,
    this.enabled = true,
    this.biasLat,
    this.biasLng,
  });

  @override
  State<PlaceAutocompleteField> createState() => _PlaceAutocompleteFieldState();
}

class _PlaceAutocompleteFieldState extends State<PlaceAutocompleteField> {
  Timer? _debounce;
  List<PlacePrediction> _items = [];
  bool _loading = false;

  String? _sessionToken;
  String _lastQuery = '';

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _ensureSession() {
    _sessionToken ??= widget.places.newSessionToken();
  }

  void _resetSession() {
    _sessionToken = null;
  }

  void _onChanged(String text) {
    if (!widget.enabled) return;

    final q = text.trim();
    if (q == _lastQuery) return;
    _lastQuery = q;

    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 550), () async {
      if (!mounted) return;

      if (q.length < 3) {
        setState(() => _items = []);
        _resetSession();
        return;
      }

      _ensureSession();

      setState(() => _loading = true);
      try {
        final bias = (widget.biasLat != null && widget.biasLng != null)
            ? LatLng(widget.biasLat!, widget.biasLng!)
            : null;

        final results = await widget.places.autocomplete(
          q,
          locationBias: bias,
          radiusMeters: 35000,
          sessionToken: _sessionToken,
          maxResults: 6,
        );

        if (!mounted) return;
        setState(() => _items = results);
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    });
  }

  void _selectItem(PlacePrediction p) {
    final token = _sessionToken ?? widget.places.newSessionToken();

    widget.controller.text = p.description;
    setState(() => _items = []);

    widget.onSelected(p.description, p.placeId, token);

    FocusScope.of(context).unfocus();

    // Termina la sesión tras seleccionar (ya se usará token en Place Details)
    _resetSession();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          enabled: widget.enabled,
          controller: widget.controller,
          onChanged: _onChanged,
          decoration: InputDecoration(
            labelText: widget.label,
            border: const OutlineInputBorder(),
            isDense: true,
            suffixIcon: _loading
                ? const Padding(
              padding: EdgeInsets.all(10),
              child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            )
                : (widget.controller.text.isEmpty
                ? null
                : IconButton(
              icon: const Icon(Icons.clear),
              onPressed: widget.enabled
                  ? () {
                widget.controller.clear();
                setState(() => _items = []);
                _lastQuery = '';
                _resetSession();
              }
                  : null,
            )),
          ),
        ),
        if (_items.isNotEmpty)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Colors.black12),
              borderRadius: BorderRadius.circular(12),
              boxShadow: const [BoxShadow(blurRadius: 10, color: Colors.black12, offset: Offset(0, 6))],
            ),
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: _items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final p = _items[i];
                return ListTile(
                  dense: true,
                  title: Text(p.description),
                  onTap: widget.enabled ? () => _selectItem(p) : null,
                );
              },
            ),
          ),
      ],
    );
  }
}