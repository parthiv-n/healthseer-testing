import 'package:flutter/material.dart';

/// App-wide color palette — single source of truth.
///
/// Warm neutral palette inspired by Claude/Anthropic + Stripe design systems.
/// Cold blue-gray (#F7F9FC) replaced with warm parchment tones.

// ── Brand accent ──────────────────────────────────────────────────────────────
const kNavy = Color(0xFF1B3A6B);
const kNavyLight = Color(0xFF2A5298);

// ── Semantic colors ───────────────────────────────────────────────────────────
const kGreen = Color(0xFF38A169);
const kAmber = Color(0xFFD97706);
const kOrange = Color(0xFFDD6B20);
const kRed = Color(0xFFE53E3E);

// ── Surface / background (warm neutrals) ──────────────────────────────────────
const kBg = Color(0xFFF4F3F0);          // warm parchment (was cold #F7F9FC)
const kCardBg = Color(0xFFFAF9F7);      // card surface — slightly lighter
const kMetricBg = Color(0xFFF0EFEC);    // metric tile background — warm gray

// ── Border & shadow tokens ────────────────────────────────────────────────────
const kBorderColor = Color(0x1A000000); // rgba(0,0,0,0.10) — Notion whisper
const kShadowColor = Color(0x0D000000); // rgba(0,0,0,0.05) — Claude whisper

// ── Text hierarchy ────────────────────────────────────────────────────────────
const kTextPrimary = Color(0xFF1A1A1A);
const kTextSecondary = Color(0xFF6B6B6B);
