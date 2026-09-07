# PharmaPlus Customer Portal

This is a separate customer-facing application for PharmaPlus.

## How it communicates with the pharmacy system
The customer portal and the PharmaPlus Pharmacy Management system use the **same Supabase project**. Customers place orders in this portal; pharmacy staff receive and manage those orders in the **Online Orders** section of the management system.

## Deployment
1. Upload this folder to a separate GitHub repository, for example `PharmaPlus-Customer`.
2. Enable GitHub Pages for that repository.
3. Open `config.js` and enter the same Supabase Project URL and browser-safe Publishable/anon key used by the staff system.
4. Make sure the online-ordering SQL has already been run in the same Supabase project.
5. Customers use the GitHub Pages address of this portal.

## Security
Only the Supabase browser-safe Publishable/anon key belongs in `config.js`. Never put a service-role or secret key in this application. Database Row Level Security and RPC functions control access.

## Customer flow
Create account -> Sign in -> Select pharmacy -> Browse medicines -> Add to cart -> Checkout -> Place order -> Track order status.
