---
summary: "Tencent Cloud Singapore Personal Token Plan usage, console authentication, and quota mapping."
read_when:
  - Setting up Tencent Token Plan
  - Modifying Tencent console authentication or quota parsing
---

# Tencent Token Plan

This provider reads the **Singapore Personal Edition** subscription in the international Tencent Cloud console.
It shows credits used, the credit allowance, the current period's reset date when available, and the plan tier.
It does not query model inference endpoints or require a model list.

## Setup

1. Sign in to the [Tencent Token Plan console](https://console.tencentcloud.com/tokenhub/tokenplan) in Chrome.
2. Enable **Tencent Token Plan** in Settings → Providers and leave Cookie source set to **Automatic**.
3. Refresh the provider to import the session. Browser import runs only during a user-initiated app refresh.

Automatic mode imports Chrome cookies, keeping profiles separate. Successfully validated cookies are cached using
the shared provider cookie cache. An expired cached session is cleared; sign in again and refresh to import a new one.

For Manual mode, paste the console request's `Cookie` header in the secure Cookie header field.
The header needs `skey` (or `p_skey`) and `uin`, plus any other cookies sent by your console session.
The inference API key used by OpenCode cannot authenticate this quota endpoint.
Treat this header as a credential and do not paste it into issues or logs.

The CLI accepts `--provider tencent-token-plan --source web` (aliases: `tencent`, `tencenttokenplan`).
Set `TENCENT_TOKEN_PLAN_COOKIE` to your console cookie header, or use the provider's manual cookie configuration.
Manual mode uses only its configured header; Off disables all cookie sources.

## Data source

The implementation follows the international console's published
[Token Plan bundle](https://static.cloudcachetci.com/qcloud/tea/app/tokenplan.en.991afd3f80.js) and
[console transport bundle](https://static.cloudcachetci.com/qcconsole/web/en/common.c080561c62.js).

- POST `https://console.tencentcloud.com/cgi/capi`, action `DescribeTokenPlanPersonalPackage`, service `tokenhub`.
- Request body: `regionId: 9`, API `Version: 2026-03-22`, `ProductType: personal`, `Language: en-US`.
- Authentication: console cookies and the console's CSRF hash of the decoded session key.
- Allowance: `TotalCredits`; usage: `TotalUsed`. These are credits with no token or currency conversion.
  `CycleCredits` is not the displayed allowance.
- Reset: `PeriodEndDate`. `ExpireTime` is subscription expiry and is never substituted for a reset.
- Tier: the recognized `PrepayInquiryKey` values map to Lite, Standard, Pro, and Max; unknown tiers display Personal.
- Inactive subscriptions and malformed quota values report errors. `USED_UP` retains the exhausted quota display.

Explicit ISO timestamps retain their timezone. Missing, timezone-less, or unrecognized timestamps leave the reset
unspecified; the provider does not infer the API's timezone from the selected region.

## Validation and limitations

The successful-response fixtures use synthetic values derived from the public console contract. A read-only probe
confirmed the expired-session envelope (`code: 50`); a successful live balance response has not yet been verified.
The console endpoint is private and may change. Mainland China and Team Edition are outside this provider's scope.
