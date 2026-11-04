# IDP extraction stub outputs (temporary)

These are hand-built test stubs, not real IDP responses. Each file was made by reading the sample PDF in `sample-docs/` and applying its schema's field descriptions by hand. No endpoint was called. Values use the value-only form: every schema field is a string, and every table is an array of row objects.

| Output file | Source doc | Fields filled / empty | Table rows |
|---|---|---|---|
| AddressVerificationDocumentExtractionSchema.output.json | Address_Verification_Ridgeline_Northstar.pdf | 6 / 0 | AddressTable = 6 |
| AddressVerificationElectricBillExtractionSchema.output.json | COPL_Electric_Bill_Sep2026.pdf | 5 / 1 | (none) |
| DealerApplicationExtractionSchema.output.json | Dealer_Application_Ridgeline_Northstar.pdf | 27 / 0 | DirectOwners = 2, IndirectOwners = 2, KeyManagement = 4 |
| OrgChartExtractionSchema.output.json | Org_Chart_Ridgeline_Northstar.pdf | 7 / 0 | (none) |
| FacilityImageExtractionSchema.output.json | Photographs_of_Facility_Ridgeline_Northstar.pdf | 22 / 0 | (none) |

The Address Verification rows "Service & Parts" and "Parts Shipping" are `Corrected`, and Column B is set to 4901 Morse Road, Building B (Parts Shipping adds "Dock 3" and receiving hours). The other 4 rows are `Confirmed`.

## Uncertain fields

- **Multi-line address cells** (`AddressTable.AddressOnFileWithNMC` / `AddressCorrectedInformation`): line breaks are kept as `\n`. The real IDP may join the lines with spaces instead.
- **`DealerApplication.OwnershipInfoDirectOwners[1].DateOfBirth`**: kept the literal `N/A — Entity`. The MM-DD-YYYY rule can't apply to it, and the real IDP might return `""` instead.
- **Boolean casing**: the Dealer App descriptions say `True`/`False`, and the Org Chart and Facility descriptions say `true`/`false`. Each file uses the casing its own schema gives.
- **`OrgChart.OwnershipStructure` / `Facility.AreasPhotographed`**: the schema asks for a JSON array. Here the array is stored as a JSON-encoded string, so all values stay strings. Parse it with `JSON.deserialize`.
- **`OrgChart.OwnershipStructure`** includes Marcus J. Whitfield → Morse Rd. Realty Holdings LLC (100%). That share is stated in the landlord box, not drawn as a connector. The "Effective ownership" table (calculated values) is not included.
- **`OrgChart.DealerLegalName`**: taken as the all-caps title `RIDGELINE NORTHSTAR OF COLUMBUS, LLC`, as written on the chart.
- **`ElectricBill.AccountHolderAddress`**: the bill prints `COLUMBUS OH 43230-1563`. Commas were added to match the format the schema asks for ("Street, City, State ZIP").
- **`DealerOperatorAndKeyManagement.DateOfHire`**: kept as MM/DD/YYYY because the column asks for no date transformation.

## Doc vs schema gaps

- `ElectricBill.UtilityProviderEmail` is empty because the bill has no email address, only the website `copl-energy.com`.
- The schema's G1 question text ("no test", "ir any crime") has typos. The document says "no contest" and "or any crime".
- The Address Verification column descriptions say "PART 1 - ADDRESSES", but the table is in PART 2.
- `CountryParcelNumber` is the doc's "COUNTY PARCEL NO." (the field name has a typo).
