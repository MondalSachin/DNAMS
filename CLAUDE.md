# DNAMS POC — Claude project notes

Salesforce DX project for a dealer package review POC. Dealers receive an emailed link, upload documents to
their **package** on a public Experience site and submit it; at **Dealer Submitted** an AI pipeline (not built
yet) will classify the documents. In production, packages will arrive already submitted with documents; the
site + email flow exists to demonstrate that. Keep this file updated after every build slice.

- Target org alias: `dnams` (SDO, `sachin.mondal@cloudkaptan.com.dnams.sdo`), API 68.0.
- AI work must follow the user's AI Excellence Framework: `/Users/sachinmondal/Desktop/AI Excellence/*.xlsx`
  (topics G1–G8; cite item IDs).
- Working agreement: list all doubts and confirm every API name with the user **before** building.
  Do not invent names.

## Current design

**Data model** (`force-app/main/default/objects`)

| Object | Purpose | Fields |
|---|---|---|
| `DNAMS_Package__c` (Package) | One package per dealer request; never reused | Name = Package Number (AutoNumber `DNAP-{0000000}`), `Package_Name__c`, `Type__c`, `Status__c`, `Buying_Dealer__c` (Account), `Selling_Dealer__c` (Account), `Primary_Contact__c` (Contact, filtered to buying dealer), `Dealer_Submit_Validation_Override__c`, `Upload_Token__c` (unique, case-sensitive, 64 hex), `Upload_Link_Sent_To__c`, `Upload_Link_Sent_At__c`, standard Owner |
| `DNAMS_Package_Element__c` (Package Element) | Created new for each package; never reused | Name = Element Name, `Element_Number__c` (AutoNumber `DNAE-{0000000}`), `Package__c` (**Lookup**, restrict delete), `Element_Type__c` (Lookup), `Is_Required__c`, `Sort_Order__c` (both copied from the type at creation) |
| `DNAMS_Element_Type__c` (Element Type) | **The only thing carried over** between packages; admin-maintained from its tab | Name, `Instructions__c`, `Is_Active__c`, `Sort_Order__c`, `Is_Required__c` |

- (Superseded 2026-11-09, see "Package setup" below: elements now come from `DNAMS_Package_Type_Element_Map__c` and are
  created on insert.) Every active Element Type is added to every new package (any package type).
- `DNAMS_Package_Type_Element__c` (per-package-type mapping) existed in slice 1 and was **deleted** in slice 2
  at the user's request.
- `Type__c` uses Global Value Set `DNAMS_Package_Type`: Buy/Sell change of Ownership, Term Renewal, Dealer
  Principal Change. `Status__c`: Draft (default), Initiated, Dealer Submitted, RMR Pending, Under Review,
  Review Failed, Review Passed, Returned, Dealer Executed, Closed (see "Package status lifecycle" below).
- Documents are standard Files linked to the **element** (`ContentDocumentLink`).
- `ContentVersion.DNAMS_Upload_Token_fileupload__c`: set by the guest upload component to `elementId:token`.
- Validation rules: `Type_And_Buying_Dealer_Required`, `Selling_Dealer_Required_For_Buy_Sell`.
- Queue `CENTRAL_RMR`; Lightning app `DNAMS` (tabs Packages, Package Elements, Element Types); page layouts
  for all 3 objects in `layouts/` (auto-created layouts lack custom fields, so layouts are source-controlled).
- Permission set `DNAMS_Package_Access` (internal users; assigned to the admin user). Without it new fields
  are invisible and Apex tests fail with "fields being inaccessible".

**Behaviour** (`DNAMS_PackageService`, `without sharing`, called from triggers)

- Insert: generates `Upload_Token__c` (`Crypto.generateAesKey(256)` as hex).
- Package Name = `<buying dealer AccountNumber> - <Type> - <selling dealer AccountNumber>` (selling part
  omitted when blank; Account Name fallback for temp dealers). Recomputed when Type/dealers change.
- Status → **Initiated** (insert or update) creates the package's own elements from active Element Types,
  sorted. Idempotent (Returned → Initiated does not duplicate).
- Status → **Dealer Submitted**: unless the override flag is set, blocks when there are no elements or a
  required element has no file; then sets Owner = CENTRAL RMR queue.
- Files on elements are locked unless status is Draft / Initiated / Returned (new links, new versions and
  guest uploads are all rejected).
- Guest uploads: `DNAMS_ContentVersionTrigger` before insert validates `elementId:token` (exact,
  case-sensitive match against the element's package token; editable status); after insert links the file
  to the element.

**Public site** "DNAMS Dealer Portal" (Build Your Own LWR): `https://cl1793616242225.my.site.com/dnamsdealer`
- Public access enabled (`sfdc_cms__site` `authenticationType = AUTHENTICATED_WITH_PUBLIC_ACCESS_ENABLED`);
  login still available (internal users allowed; System Administrator profile is a member).
- Home page has two components:
  - `dnamsPackageSender`: **logged-in users only** (renders nothing for guests; guests also lack access to its
    class `DNAMS_PackageController`). Lists packages not yet submitted, with a recipient email box and
    **Send Link**, which emails the upload link and stamps Sent To / Sent At.
  - `dnamsPackageUpload`: reads `?token=` from the URL. Shows the package's 22 elements with instructions, upload
    on required elements, and **Submit Package**; read-only after submit. Without a token, guests see "open
    the link from your email".
- Guest profile `DNAMS Dealer Portal Profile`: **no object permissions**; Apex access to
  `DNAMS_GuestUploadController` only (`profiles/` holds just that class access). That controller is
  `without sharing`, finds the package by exact token, returns file names only (no file ids/downloads) and
  can only submit an editable package. Org setting "Allow site guest users to upload files" was already on.
- After site metadata changes run `sf community publish -o dnams --name "DNAMS Dealer Portal"`.

**Data scripts** (`scripts/apex`, all re-runnable)
- `dnams-seed-element-types.apex`: 22 element types in the user's order; required = Dealer Application,
  Address Verification, Photographs of Facility, Org Chart. Instructions from the user's sheet (typos fixed).
- `dnams-reset-demo.apex`: deletes all packages, elements and their files (keeps element types).
- `dnams-seed-demo-packages.apex`: 12 Term Renewal packages at Initiated for existing business accounts
  (not person accounts) with a dealer code and a contact with email. Current demo: DNAP-0000062 … DNAP-0000073.

**Tests**: `DNAMS_PackageServiceTest`: 11/11 pass. Coverage: service 98%, sender controller 96%, guest
controller 100%, triggers 100%.

### Guest access fix (2026-11-03): the upload link failed with "sObject type 'DNAMS_Package__c' is not supported"
- **Cause 1:** the guest profile had no object access, and the org rejects guest Apex queries on objects the profile
  can't read. The guest profile now has **Read only** on Package, Package Element and Element Type, field read on the
  fields the page uses, and edit on `ContentVersion.DNAMS_Upload_Token_fileupload__c`. Still no create/edit/delete
  and no sharing.
- **Cause 2:** for the site guest on API 68, a `without sharing` class's static SOQL still returned **0 rows**
  (diagnosed: normal query 0, `AccessLevel.SYSTEM_MODE` 1). All queries in `DNAMS_GuestUploadController` and
  `DNAMS_PackageService` now use `WITH SYSTEM_MODE`, and their DML uses `AccessLevel.SYSTEM_MODE`.
- The dealer's Account name was removed from the guest page (it would need Account access); the Package Name
  carries the dealer code.
- `DNAMS_GuestAccessTest` runs open → remove → submit as the real site guest user. File inserts are done as the
  platform would, because a guest's direct Apex ContentVersion insert fails with "private library must be owned by
  that user". Real uploads use lightning-file-upload.

## Build log
- **Slice 1 (2026-11-03):** Package/Element objects, per-package-type config object, logged-in site with
  create/start/upload/submit, page layouts.
- **Slice 2 (2026-11-03):**
  - Removed the per-package-type config object and the create/start screens (old LWC
    `dnamsPackageWorkspace`). Order and required moved onto Element Type.
  - Made the site public with token links and a least-privilege guest.
  - Added the email-link sender, the demo seed and reset scripts, and a clean demo (12 packages).

## Commands

```bash
sf project deploy start -o dnams -d force-app --test-level RunSpecifiedTests --tests DNAMS_PackageServiceTest
sf apex run test -o dnams -n DNAMS_PackageServiceTest -c -r human -w 15
sf apex run -o dnams -f scripts/apex/dnams-seed-element-types.apex
sf apex run -o dnams -f scripts/apex/dnams-reset-demo.apex
sf apex run -o dnams -f scripts/apex/dnams-seed-demo-packages.apex
sf community publish -o dnams --name "DNAMS Dealer Portal"
```

## Org changes outside the repo
- Site created with `sf community create` (then metadata retrieved into the repo).
- `DNAMS_Package_Access` assigned to the admin user.
- User added an IPv6 Login IP Range to the System Administrator profile in Setup (their network reaches
  `my.site.com` over IPv6; the profile's "ALL" range was IPv4-only → "Restricted IP"). Not in the repo.

## Gotchas learned
- `sf project deploy validate` rejects `--test-level NoTestRun`; use `deploy start --dry-run`.
- `--post-destructive-changes` needs `--manifest`; generate it with
  `sf project generate manifest --source-dir force-app --output-dir <dir> --name package` (`-d` there means output dir).
- `AuraHandledException.getMessage()` returns "Script-thrown exception" unless `setMessage()` is called; it
  cannot be thrown from anonymous Apex.
- Apex: no `Collections.disjoint`; inner classes cannot have static methods; string `==` is case-insensitive
  (use `equals()` for tokens).
- `Owner.Name` on a queue-owned record came back null inside a test; assert on `OwnerId`.
- Deleted custom objects still appear in Tooling `CustomObject` queries for ~15 days; check with `sobject describe`.

## AI review pipeline (slice 3, 2026-11-03) — diagram v2 steps 2, 3, 5a, 5b, 6–17, 22, 23 (stub)

Tier 2 (G1.14): Apex skeleton + one prompt template; no agent. User approved my recommendations for all
open questions and asked to skip the golden test set for now.

- **Package rules added:** Dealer Submitted only from Initiated or Returned (`SUBMIT_FROM_MESSAGE`); CENTRAL RMR
  queue assigned on the first submit only (a resubmit keeps the RMR user).
- **Step 2:** the package trigger publishes `DNAMS_Package_Review_Requested__e` (PublishAfterCommit) on
  Initiated→DS / Returned→DS. `DNAMS_PackageReviewRequestedTrigger` runs as the admin user via
  `PlatformEventSubscriberConfig` `DNAMS_PackageReviewRequestedConfig` (batch size 1). The site guest can't call
  Einstein, so the pipeline must never run as the guest.
- **`DNAMS_PackageReviewPipelineService`:**
  - step 3: is a Running or Cancelling run active?
  - steps 5a/5b: Discarded run, plus an email to the owner if the owner is a user; a queue-owned package is
    recorded on Reason only (step 19 rule);
  - steps 6/7: Running run, then enqueue the starter;
  - steps 16/17/22/23: `completeClassification`.
  - `lockRun` re-checks the status at every step (Cancelling → Cancelled).
- **`DNAMS_ClassificationStarterQueueable`** (steps 8–10, 12): one `AI_Document_Classification__c` per file
  (latest version) on every element.
- **`DNAMS_DocumentClassificationBatch`** (steps 12–15):
  - scope from settings;
  - all model calls first, then DML;
  - retry up to Max Attempts, then Error;
  - LOW (below the min confidence) → Unclassified;
  - stamps ContentVersion `DocumentClassifiedAs__c` etc.
- **`DNAMS_DocumentClassifier`** interface. `DNAMS_EinsteinDocumentClassifier` calls
  `ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate` with `Input:document` and `Input:element` set to
  `{id: ...}`. Tests inject a stub.
- **Running user:** the subscriber config only took effect after the user did **Setup → Platform Events → DNAMS Package
  Review Requested → Subscriptions → Manage → Suspend, then Resume**. Before that the trigger ran as Automated Process
  and every model call failed with "Connect API is not enabled for this user type". Redeploying the trigger did
  not help. Repeat Suspend/Resume after changing the config or deploying to a new org.
- **Live E2E verified (RUN-000058, run by Sachin Mondal):** 3 correct PDFs → Match/FULLY; a lease agreement in the
  Org Chart slot → Wrong Type "Commercial Lease Agreement"; elements Green/Red, package Red, run Needs Review.
  The temporary test package was deleted afterwards.
- **Prompt `DNAMS_DocumentClassifier_Prompt`** (flex, `sfdc_ai__DefaultGPT4Omni`):
  - inputs: a File (ContentDocument) and a Package Element;
  - asks whether the document matches the element's expected type, using
    `Element_Type__r.Identifying_Definition__c` and `Instructions__c`;
  - returns JSON `{matches_expected, document_type, confidence, reasoning}`.
- **Step 16 rules:** issue on Missing (required element with no file), Wrong Type, Unclassified, or Error. Health
  Red/Green is set on elements (blank when not required and no file) and on the package. Run → Completed with
  Overall Passed or Needs Review. Passed enqueues `DNAMS_ExtractionStarterQueueable` (placeholder).
- **New objects:**
  - `AI_Package_Review_Run__c` (tab in the DNAMS app);
  - `AI_Document_Classification__c` (master-detail to Run);
  - `DNAMS_Pipeline_Setting__mdt.Default`: batch 4, max attempts 2, min confidence MODERATE, template name.
- **New fields:** Package `Health__c`; Element `Health__c`, `Issue__c`; Element Type `Identifying_Definition__c`
  (definitions are my drafts, in the seed script, and need user review).
- **Tests:** `DNAMS_PackageReviewPipelineTest` (13) + `DNAMS_PackageServiceTest` (12) all pass.
  `DNAMS_EinsteinDocumentClassifier` is 0% because live LLM calls can't run in tests.

**Prompt template deploy gotchas:**
- This org does not auto-activate deployed templates, so the repo file carries `activeVersionIdentifier` and
  `versionIdentifier`.
- Adding a required input to an existing template is rejected as an "unsafe change"; delete and recreate it.
- Apex grounding (`CapabilityType='FlexTemplate://…'`) kept failing with "capabilityType isn't available" even with an
  active template, so it was dropped in favour of a record input.

## Slice 4 (2026-11-03): HITL, steps 17–21, step 1b

**HITL** (user's design, G4.19/G4.20/G1.24):
- Confidence bands come from `DNAMS_Pipeline_Setting__mdt`: `Min_Auto_Accept_Confidence__c` (FULLY) → accepted; at or
  above `Min_Accepted_Confidence__c` (MODERATE) → `Needs Human Review`; below → Unclassified.
- The batch finish pauses the run: Run `Awaiting Review` (also the classification status), Package → `RMR Pending`,
  owner notified (step 19 rule).
- The RMR confirms (keeps the AI answer) or corrects (picks one of the 22 types or "Not a valid document").
- `recordDecision` stores `Human_Decision__c`, `Human_Classified_As__c`, `Reviewed_By__c`, `Reviewed_At__c` and
  `Review_Comment__c`, and recomputes Match/Wrong Type. It stamps the ContentVersion `Human_Verified__c` with the final type.
- After the last decision the run resumes at step 16 (`completeClassification`) with no re-classification.

**Steps 16–23:**
- Package status after a run: Needs Review → `RMR Pending`; Passed → `Under Review`.
- `Run.Issue_Summary__c` holds the per-element issues.
- Issues → `DNAMS_PackageNarrativeQueueable` (steps 18–20):
  - prompt `DNAMS_PackageIssueNarrator_Prompt` (input: the run), with a fallback to the issue summary;
  - writes `Package.AI_Narrative__c`, always shown with `AI_LABEL` (G4.23);
  - `notifyOwners`: email only when the owner is a user with the `DNAMS_RMR` permission set, otherwise recorded on
    Run.Reason (queue-owned).
- Passed → the extraction placeholder.

**Step 1b, step 21 and the HITL decisions use standard Salesforce UI only (no custom LWC; the user's explicit
requirement).** Each button is a Quick Action → Screen Flow → invocable Apex → `DNAMS_RmrReviewService`.

| Button (record header) | Object | Flow | Invocable |
|---|---|---|---|
| Return to Dealer | Package | `DNAMS_Return_To_Dealer` (email defaulted from the Primary Contact) | `DNAMS_ReturnToDealerAction` |
| Re-run Review | Package | `DNAMS_Rerun_Review` | `DNAMS_RerunReviewAction` |
| Cancel Review | Package | `DNAMS_Cancel_Review` | `DNAMS_CancelReviewAction` |
| Confirm AI | AI Document Classification | `DNAMS_Confirm_AI_Classification` | `DNAMS_ReviewDecisionAction` |
| Correct Classification | AI Document Classification | `DNAMS_Correct_Classification` (picklist of active Element Types + "Not a valid document") | `DNAMS_ReviewDecisionAction` |

- The invocables never throw: a failure comes back as "Not done: <reason>" and is shown on the flow's result screen.
- The starter links each file to its `AI_Document_Classification__c` record (ContentDocumentLink, InternalUsers), so
  reviewers preview it in the standard **Files** related list.
- Review queue: the **AI Document Classifications** tab with list view **Needs Human Review**.
- **Package dashboard** (`DNAMS_Package_Record_Page`, template `flexipage:recordHomeTemplateDesktop` = Header and Right
  Sidebar; standard components only, per the user):
  - **Header:** highlights (compact layout `DNAMS_Dashboard`: Name, Package Name, Status, Health, Type, Dealer)
    and a Path on Status (`pathAssistants/DNAMS_Package_Status`).
  - **Main:** Tabs — Details, Elements (`Package_Elements__r`), AI Reviews (`AI_Review_Runs__r`), Documents
    (`AttachedContentDocuments`), History (`Histories`).
  - **Sidebar:** Rich Text alerts with visibility rules on Status and Health:
    - Human review needed: RMR Pending and Health neither Red nor Green. The pipeline clears Health on pause.
    - Issues found: RMR Pending and Red.
    - All verified: Green.
    - Returned.
    - AI review in progress: Dealer Submitted.
    - Waiting for dealer: Initiated.
  - **Sidebar, also:** a Dynamic Forms "AI Summary" section (Health, AI Narrative, link sent to/at) and the latest
    3 review runs.
  - **FlexiPage gotchas:** `force:relatedListSingleContainer` accepts only parentFieldApiName, relatedListApiName,
    relatedListComponentOverride, rowsToDisplay (max 30) and showActionBar.
- **Files on Package:** the `DNAMS_ContentDocumentLinkTrigger` after insert/delete mirrors element files onto their
  package (`mirrorElementFilesToPackages` / `unmirrorElementFilesFromPackages`); the file stays while any element of
  that package still has it.
- **Red attention banners** (a standard Rich Text component with a visibility rule, set as the View override):
  - `DNAMS_Document_Classification_Record_Page` shows the banner when Status = Needs Human Review;
  - `DNAMS_Review_Run_Record_Page` shows it when Status = Awaiting Review. FlexiPage visibility rules here reject
    `GREATER_THAN`, so the rule is on status.
  - Compact layout `DNAMS_Review` puts Status, Expected, Classified As, Confidence and Match in the classification header.
- The site's `dnamsPackageSender` is hidden when the URL has `?token=`, so an upload link shows only its own package
  even to logged-in users.
- An earlier LWC panel (`dnamsPackageReviewPanel`) and `DNAMS_RmrReviewController` were deleted.
- All actions need the custom permission `DNAMS_RMR` (permission set `DNAMS_RMR`, assigned to the admin user).
- Cancel: an Awaiting Review run → Cancelled at once; a Running run → Cancelling.
- Re-run: publishes the review event with source `RMR Rerun`. Allowed only when no run is active and the status is
  Dealer Submitted, RMR Pending or Under Review.
- Return to Dealer: status → Returned, and the upload link, narrative and issues are emailed to the entered address
  (default: the Primary Contact).

**Dealer page:** when Returned, it shows the narrative (AI label) and each element's issue, allows uploads on required
or flagged elements, and lets the dealer remove files (`removeDocument` unlinks the file from the element).

**Tests:** `DNAMS_RmrReviewTest` (12) + pipeline (13) + package (13) = 38, all passing. The `Run__c` master-detail on a
queried row is not updateable in this org; update a fresh sObject with only the changed fields.

## Slice 5 (2026-11-03): element-level results; document object and HITL removed

User decisions:
- Store results per **element**, not per document. **Deleted:** `AI_Document_Classification__c` and everything on it
  (layout, tab, list view, record page, the Confirm AI / Correct Classification quick actions, their flows,
  `DNAMS_ReviewDecisionAction`).
- **No human-review pause and no decision buttons.** MODERATE results become the element status **Needs Review**,
  and the run carries on.
- **Removed fields:** Element `Health__c` and `Issue__c`; Run rollups Total / Matched / Awaiting_Review_Documents.

**New fields on `DNAMS_Package_Element__c`:**
- Stage statuses `Classification_Status__c`, `Extraction_Status__c`, `Rule_Validation_Status__c`,
  `Transmittal_Status__c`, all with values Not Started / In Progress / Passed / Needs Review / Failed. Only
  Classification is filled; the other stages stay empty until they are specified.
- `Current_Stage__c`.
- `Element_Narrative__c` (Text 255, rule-based, non-AI, blank when passed). The dealer page shows it as the issue.
- `Classified_As__c`, `Classification_Confidence__c` (lowest across files), `Classification_Reasoning__c`.

**Pipeline:**
- The starter resets every element's stage fields and marks elements with files as Classification In Progress.
- The batch runs over **elements**; each file gets its own retried call and its own ContentVersion stamp, which is
  kept.
- Element result: Failed if any file is wrong, unclassified or errored; else Needs Review if any is MODERATE; else
  Passed.
- `completeClassification`: a required element with no file → Failed "required document missing"; anything still
  In Progress → Failed "did not finish".
- `Issue_Summary__c` = the stuck elements' narratives → the package AI narrative (still AI, the narrator prompt).
- `ACTIVE_RUN_STATUSES` = Running and Cancelling. Cancel only applies to a Running run.

**Dashboard:** the AI Reviews tab is replaced by **Element Progress**, a standard `lst:dynamicRelatedList` on
`Package_Elements__r`. A custom object's Name column alias is `NAME`. The "Human review needed" banner was removed.
- Columns: NAME, then the four **icon** fields, then Element Narrative. Per the user: no Is Required or Current Stage
  columns, and icons rather than text.
- The icon fields `Classification_Icon__c`, `Extraction_Icon__c`, `Rule_Validation_Icon__c` and
  `Transmittal_Icon__c` are formula `IMAGE("/resource/DNAMS_Icon_<Passed|Failed|Needs_Review|In_Progress>")`.
- The SVGs are static resources: green tick, red cross, amber warning, blue clock. A blank status shows no icon.
- The picklists are relabelled "<Stage> Status".
- Element narratives have no stage prefix; they start with a capital, e.g. "Found X instead of Y…".

**Deleting active flows that quick actions use, in this order:**
1. Replace the layout's `platformActionList` with Edit only.
2. Delete the quick actions.
3. Deactivate via FlowDefinition `activeVersionNumber` 0.
4. Delete the flows by version (`Name-1`).
5. Then delete the class, fields and object; the object takes its record page with it.

## Slice 6 — reverted (2026-11-03)
A move of the classification config to custom metadata (Element Definition / Document Type / Element Document Type,
several accepted types per element, `DNAMS_ElementConfig`, `Element_Key__c`, `Accepted_Document_Types__c`) was built
and then **fully reverted at the user's request**. Current state is the slice 5 design:
- Config = `DNAMS_Element_Type__c` records (tab "Element Types"), seeded by `scripts/apex/dnams-seed-element-types.apex`
  (rebuilt from the org records).
- Elements link to it via the `Element_Type__c` lookup (recreated). One expected type per element.
- The classifier prompt uses `Element_Type__r.Identifying_Definition__c` / `Instructions__c`.
- The custom metadata types, config classes and the two fields were deleted from the org.
- The leftover deleted field `Element_Type_del__c` still sits in Deleted Fields (harmless; erase in Setup if wanted).
- Kept from before the change: Element Progress icons, prefix-free narratives, the guest-access fix and
  `demo-docs/correct/Utility_Bill.pdf`.
- Gotcha (still true): to change a prompt template's wording, delete and recreate the template, then set
  `activeVersionIdentifier` again.
- **Superseded since (extraction branch):** accepted document types per element now live in custom metadata
  `DNAMSElementDocumentType__mdt` (23 records: `ElementType__c` = Element Type **Name** as text, `DocumentType__c`,
  `IdentifyingInstructions__c`, `IsRequired__c`, `SortOrder__c`, `IsActive__c`), read by `DNAMSElementDocumentTypeUtil`
  for the classifier prompt and the match check. Address Verification accepts two types (form + utility bill). Renaming
  an Element Type record breaks its mapping. Which elements a package gets is still "every active Element Type" (no
  per-package-type mapping).

## Next (not started)
- PIR status in the RMR email (definition needed from the user).
- Element `Transmittal_Status__c` / `Current_Stage__c` are not set by transmittal drafting yet, so the Element Progress
  Transmittal icon stays blank.
- Element Progress does not refresh itself when async Apex updates elements (page reload needed).
- `DNAMS_GuestDiagnostic` (org debug class, no tests) — delete if not needed.
- The golden test set (G8.05) and review of the 22 identifying definitions.
- Review timeout / escalation (G1.15) if wanted.

## Rule validation (2026-11-04) — rule validation diagram steps 1–23 (built on top of Abhishek's extraction branch)
- Rules: `DNAMSRule__mdt` (30 records, source of truth `rule_validation/DNAMSRules.json`; DeveloperName = rule id, e.g.
  `DA_V01`). Keys: `extraction.<IDP action>.<field>` (top-level fields only), `Package.<lookup>__r[.<rel>].<field>`
  (≤3 levels), Static literals / JSON lists, `{TODAY-n}`. User asked: no `[*]`, filters or `sum()`.
- Flow: extraction completion → `DNAMSRuleValidationStarterQueueable` (rules + PIR, ExactMatch in `DNAMSRuleEvaluator`)
  → `DNAMSAIRuleValidationQueueable` (AIMatch, prompt `DNAMS_RuleValidation_Prompt`, ≤50 per call, retries → CANNOT_DECIDE)
  → `DNAMSRuleValidationCompletionHelper` (pass rate excl. NOT_APPLICABLE; 100% Green / ≥85% Amber / else Red; failed
  PIR → Red). Green: package Under Review, run stays Running → narrative + owner email → `DNAMSTransmittalStarterQueueable`
  (transmittal drafting, see below). Amber/Red: package RMR Pending, run Completed/Needs Review, narrative + email.
- Results: one `AIReviewStageResult__c` per rule (`Stage__c` Rule Validation; RuleId/RuleName/ComparisonMethod/
  SourceValue/ReferenceValue/Verdict). Run: `RuleValidationProcessingStatus__c` + 3 pass-rate fields. Package
  `Health__c` gained Amber; PIR checkboxes `PIR_Linked__c`, `PIR_Cleared__c`, `PIR_Bypass_Acknowledged__c`,
  `PIR_Bypass_Reason__c`; settings `PIRRequiredPackageTypes__c` (Buy/Sell; Dealer Principal Change),
  `RuleValidationBatchSize__c`, `RuleValidationPromptTemplate__c`.
- Tests: `DNAMSRuleValidationTest` (10). Deploy only changed paths: `sf project deploy start -d force-app` would
  overwrite the two profiles that differ in the org, and this org runs **no tests on deploy/validate** — run
  `sf apex run test` afterwards.
- Not yet verified live: AIMatch prompt call as the IDP integration user (needs Einstein access).

## Required document types (2026-11-05)
- `DNAMSElementDocumentType__mdt.IsRequired__c` (checkbox). Required: Dealer Application, Address Verification Form,
  Utility Bill, Photographs of Facility, Org Chart (so Address Verification needs both the form and a utility bill).
- `DNAMS_DocumentClassificationBatch.elementResult`: each required type with no file classified as it (FULLY match or
  MODERATE naming it) fails the element ("Utility Bill missing. Upload a Utility Bill to Address Verification."), so the
  run stops at classification. Only applies to elements that have files; an empty required element still fails as
  "Required document missing" in `completeClassification`.
- Address Verification `Instructions__c` now asks for both documents (org record + seed script).
- Test: `DNAMS_PackageReviewPipelineTest.missingRequiredDocumentTypeFailsElement`, `DNAMSElementDocumentTypeUtilTest`.

## Rule Type and Verdict on stage results (2026-11-05)
- `AIReviewStageResult__c.RuleType__c` (restricted picklist Completeness / Validation), set by
  `DNAMSRuleValidationStarterQueueable` from `DNAMSRule__mdt.RuleType__c`; the PIR row is Validation. Shown in the
  Rule Validation section of `DNAMS_Stage_Result_Record_Page` and the full layout. Old rows backfilled with
  `scripts/apex/dnams-backfill-rule-type.apex`.
- `Verdict__c` added (after Processing Status) to the Stage Results related lists on the Review Run and Package
  Element layouts.

## Harbor Motors branding and business stage names (2026-11-06)
- Demo brand **Harbor Motors** (user's choice; DNAP/DNAE numbers kept). Logo: static resource `HarborMotorsLogo` (SVG,
  Public cache; guests load it via `/sfsites/c/resource/`). LWC `dnamsBrandHeader` is the first component on the
  site Home page; site title "Harbor Motors Dealer Portal". The site/network name stays "DNAMS Dealer Portal"
  (`DNAMS_PackageController.SITE_NAME` looks it up). Internal Lightning app label still "DNAMS".
- Email subjects: "Harbor Motors: upload documents…", "Harbor Motors: package … was returned…", "Harbor Motors <pkg>: …";
  dealer emails sign off "Harbor Motors Dealer Network".
- Stage display names (labels only; keys, fields and Stage__c values unchanged): Classification → All Documents
  Present, Extraction → Document Reading, Rule Validation → Is Document Valid and Complete. Used in
  `DNAMS_PackageInsightsController.STAGE_LABELS`, the three `*_Icon__c` field labels (Element Progress columns) and
  the Stage Result page tab titles.
- Lightning app `DNAMS` (API name unchanged) relabelled **Harbor Motors** with brand header colour #0B3A5B and logo
  ContentAsset `HarborMotorsLogo` (PNG); the site's emailSenderName is "Harbor Motors Dealer Portal".

## Re-run / Cancel Review pre-check (2026-11-06)
- Flows `DNAMS_Rerun_Review` and `DNAMS_Cancel_Review` (v2) start with `DNAMS_ReviewActionCheck` (invocable, action
  Rerun|Cancel → `DNAMS_RmrReviewService.checkAction`): decision `Can_Proceed` → Confirm (shows the check message) →
  action → Result; otherwise `Not_Available` shows why at once (no review running / review RUN-x still in progress /
  package not yet submitted / not an RMR). Class access in permission set `DNAMS_RMR`. Test:
  `DNAMS_RmrReviewTest.checkActionExplainsBeforeConfirming`.

## Package UI insights and structured AI summary (2026-11-05/06, Sachin, commit 99645e8)
- Narrative is now **structured**: `DNAMS_PackageNarrativeQueueable.buildFacts` builds facts JSON (elements with stage
  statuses, failing rules with compared values) → prompt `DNAMS_PackageIssueNarrator_Prompt` input `Input:facts` (was
  `Input:run`; `DNAMS_NarrativeWriter.write(template, factsJson)`). Output JSON stored in Package `AI_Narrative_JSON__c`,
  plain text in `AI_Narrative__c`, facts in Run `Narrative_Input__c`. Model failure → rule-based fallback summary.
  `AI_LABEL` = "AI-generated summary.". Optional chained `next` Queueable (used for GREEN → transmittal).
- Rule validation element status is pass/fail only (no Needs Review): Passed when every applicable rule passed.
- `DNAMS_PackageInsightsController` (`getAiSummary`, `getElementProgress`, `getDocuments`) feeds LWCs
  `dnamsPackageAiSummary` (+ `dnamsAiSummaryView`, also on the dealer page), `dnamsElementProgressSummary`,
  `dnamsPackageDocuments` (files by element with classification results and preview) on `DNAMS_Package_Record_Page`.
- `DNAMS_Stage_Result_Record_Page` (+ `AIReviewStageResult__c` layout): shows only the tabs/fields of the row's stage.
  `AIReviewStageResult__c.Document__c` added.
- Demo scenarios: Package `Demo_Scenario__c`; scripts `dnams-seed-scenario-packages.apex`,
  `dnams-add-scenario1-packages.apex`, `dnams-reset-scenario-packages.apex` (touch only tagged data); stub resource
  `DNAMSIDPStubDealerApplicationIncomplete` for the incomplete Dealer Application scenario.

## Sync (2026-11-09)
- Fast-forwarded to remote `feature/transmittal-drafting` (99645e8, 377d103). Org vs repo compared on all 434 manifest
  components: Apex identical; other differences were retrieve formatting only, **except** `DNAMSRule.DA_V03`
  `IsActive__c` = false in the org (true in repo), changed in the org by Abhishek on 2026-11-05. Reconciled: the
  **org is the first source of truth, the repo second** (user rule) — DA_V03 is inactive in both the record and
  `rule_validation/DNAMSRules.json`.
- `manifest/package.xml` regenerated from force-app (434 members).

## Extraction (2026-11-03/04, Abhishek) — extraction diagram (Lucid p4/p5)
- Org alias on Abhishek's machine: `DNAMS_SDO` (same org as `dnams`). Branch `feature/document-extraction`.
- Flow: classification Passed → `DNAMSExtractionStarterQueueable` (one `AIReviewStageResult__c` per file, `Stage__c`
  Extraction, IDP action from `DNAMSIDPAction__mdt` by document type) → `DNAMSExtractionSubmitBatch` (multipart POST to
  MuleSoft IDP via Named Credential `DNAMSMuleSoftIDP`, or `DNAMSIDPStubCallout` in Stub mode) → IDP calls back →
  `DNAMSIDPCallbackAPI` → `DNAMSIDPEvent__e` → `DNAMSIDPCallbackQueueable` (GET result, schema check against
  `ExpectedStructure__c`) → `DNAMSExtractionCompletionHelper` (all rows terminal → run `ConsolidatedExtractionJSON__c`,
  elements' `Extraction_Status__c`, then rule validation or narrative).
- `DNAMS_Pipeline_Setting__mdt.IDPMode__c` = **Stub** (default) / Live. **Never run Live without the user's explicit
  permission** — IDP calls are expensive. Tests mock every callout.
- Callback: public Site `DNAMSIDPCallback` (guest), Apex REST `/v1/receiveIdpCallback/{token}/{actionId}/{version}/{sig}`
  (HMAC-SHA256, key in custom setting `DNAMSIDPSecret__c.SigningKey__c`; query-string form still accepted). **IDP calls
  back with HTTP PATCH** (no retry), so the resource has `@HttpPatch`/`@HttpPut`; every callback is stored in
  `CallbackPayload__c`, rejected ones logged as `Callback Rejected`.
- Stub mode: `DNAMSExtractionSubmitBatch.simulateStubCallbacks` publishes the same Callback event per submitted row,
  so stub runs settle in seconds (a failed publish is logged and left to the cleanup job).
- IDP GET body is flat: `{id, documentName, status, fields{X:{value}}, tables{T:[{C:{value}}]}}`.
- `DNAMSExtractionCleanupJob`: one scheduled job per run, `IDPTimeoutMinutes__c` (10) after submit; final GET for sent
  rows (SUCCEEDED → processed, still running → Failed (Timeout)); never-sent rows time out.
- Pre-flight gate `DNAMSFilePreflightHelper` (before classification): PDF only, ≤ 3 MB (`AllowedFileExtensions__c`,
  `MaxFileSizeMB__c`).
- Pipeline runs as integration user `dnams.idp.integration@cloudkaptan.com.dnams.sdo` (permission set
  `DNAMSIDPIntegration`, needs Read on `UserExternalCredential`). API 68 is user mode by default: pipeline SOQL/DML uses
  `WITH SYSTEM_MODE` / `AccessLevel.SYSTEM_MODE` / `as system`.
- **Per-document rows for every stage:** `AIReviewStageResult__c` holds Classification (one per file per run, written by
  `DNAMSStageResultHelper`), Extraction, Rule Validation and Transmittal Drafting rows. Errors go to `AIReviewErrorLog__c`.
- Code style: CK Apex guidelines, PMD ruleset `~/Documents/PMD/pmdRules.xml` (run without the PMD6-only custom jar).

## Sync (2026-11-05)
- Rule validation branch fast-forwarded into `feature/document-extraction`. Sachin's org-only hotfixes (stub callback
  simulation, no double completion of extraction / double start of rule validation, `WITH SYSTEM_MODE` rule query,
  page/layouts/permissions) were retrieved into the repo. **Before deploying all of force-app, diff the org against the
  repo** — hotfixes made directly in the org get overwritten otherwise.
- Rule validation queueables use `DNAMSRuleUtil.StageFailureFinalizer`, so a crash fails rule validation (not extraction).

## Transmittal drafting (2026-11-05) — transmittal diagram (Lucid p8/p9), branch `feature/transmittal-drafting`
- Only two AI summaries (user decision: no fields pre-filled from extraction): `DNAMS_Package__c.Ownership_Summary__c`
  and `Executive_Summary__c` (rich text), plus read-only `Transmittal_Drafted_At__c` and `Transmittal_Draft_Source__c`
  (Auto / RMR Draft / RMR Redraft / RMR Override).
- `DNAMSTransmittalSummaryService.draft`: builds two contexts (extraction owners/org chart/facts, package health and
  narrative, failed rules, PIR; never SSN/DOB/EIN), calls `DNAMS_OwnershipSummary_Prompt` then
  `DNAMS_ExecutiveSummary_Prompt` serially (no queue), all calls before DML. Output JSON `{"lines": [...]}` → HTML-escaped
  lines joined with `<br>`. Retry up to `TransmittalMaxAttempts__c` (3) only on rate limit / too many requests /
  unreadable output. Prompts ask for `TransmittalSummaryMaxWords__c` words (**250** since Sachin's 2026-11-06 change;
  was 50) as descriptive paragraphs, one `lines` element per paragraph; **answers are never trimmed** (user decision) —
  a longer answer is kept and noted in the log.
- Log: one `AIReviewStageResult__c` per summary (`Stage__c` Transmittal Drafting, `SummaryType__c`, `Outcome__c` = draft
  source, `Reasoning__c` note incl. who and failing-rule count, `GeneratedText__c`, `RawStageResponseJSON__c`,
  `RequestedBy__c`); every redraft adds rows, earlier ones are kept. Failures: run `TransmittalProcessingStatus__c`
  Failed + `AIReviewErrorLog__c` (Stage Transmittal Drafting); the package is left unchanged.
- Auto path: GREEN → completion helper sets `TransmittalProcessingStatus__c` Pending → `DNAMS_PackageNarrativeQueueable`
  (structured AI summary + owner email; since 2026-11-06 GREEN gets it too) → chained `DNAMSTransmittalStarterQueueable`
  drafts (source Auto) and completes the run Passed (also when drafting fails; the RMR can draft from the button). If
  the chained job can't be queued, the run's transmittal status is set Failed.
- **Draft AI Transmittal** (quick action → LWC `dnamsDraftTransmittal` → `DNAMSTransmittalController`), latest
  non-Discarded run, checked in order: no run; classification/extraction/rule validation not Completed → "still in
  progress"; transmittal Pending/In Progress → "already being drafted"; Completed → confirm redraft (RMR Redraft);
  failing rules (FAIL/CANNOT_DECIDE) → confirm "draft anyway" with count (RMR Override); else confirm (RMR Draft).
  Drafting runs synchronously (~10–20 s spinner).
- **Generate Transmittal** (LWC `dnamsGenerateTransmittal`): stub, only shows "PDF downloaded… emailed shortly".
- Record page: tab **Transmittal** with LWC `dnamsTransmittalSummaries` (scrollable boxes, max-height 12rem, inline
  edit) + Drafted At / Draft Source. Highlights panel shows 5 actions.
- Verified in Stub mode (2026-11-05): Amber run → override + redraft via controller; GREEN run → auto draft, run
  Completed/Passed, package Under Review/Green. 147/147 tests pass.
- Prompt template versions are immutable once Published: to change wording add a new version (`_2`) and set
  `activeVersionIdentifier`.

## Package setup, dealer link and guest upload (2026-11-09)
- **Element mapping:** `DNAMS_Package_Type_Element_Map__c` (tab "Package Type Element Maps"): Package_Type__c (GVS
  DNAMS_Package_Type), Element_Type__c (lookup, Restrict), Is_Active__c, Is_Required__c, Unique_Key__c (set by
  `DNAMSPackageTypeElementMapTrigger`, blocks duplicate type+element). Seed `scripts/apex/dnams-seed-package-type-element-map.apex`
  (66 rows; only Dealer Application, Address Verification, Photographs of Facility, Org Chart active+required for all
  3 types; re-running resets flags). Element Type `Is_Required__c` is no longer used.
- **Elements are created on package INSERT** (Draft) from the type's active mappings whose Element Type is active;
  Is_Required from the mapping. Initiated only creates them for old packages without elements. Insert fails with
  "No active elements are mapped for package type …" when a type has no active mapping. Type changes don't resync.
- **New Package:** standard New overridden (Aura `dnamsNewPackageOverride` → LWC `dnamsNewPackage`): Type, Primary
  Contact, Buying Dealer, Selling Dealer; toast `Package "<Package_Name__c>" was created.`. Primary Contact uses
  `lightning-record-picker` filtered to the buying dealer (lightning-input-field doesn't support the dependent
  `$Source` lookup filter; the picker rejects a filter with an empty value). Primary Contact's email is copied to
  `Upload_Link_Sent_To__c` (label "Document Uploading Email") on insert if blank.
- **Account:** quick action `Account.Create_Package` (LWC `dnamsCreatePackageFromAccount`, buying dealer = the account,
  toast with a link) on `DNAMS_Account_Record_Page`, assigned only in the DNAMS app.
- **Initiate Package/Return to Dealer** (quick action `Return_To_Dealer`, flow `DNAMS_Return_To_Dealer`,
  `DNAMS_RmrReviewService.sendOrReturn`, pre-check `checkAction(...,'SendReturn')`): Draft → email link + Initiated;
  Initiated → offer resend; later statuses → Return only if History shows Initiated + a link send (Sent To/Sent At
  history; `Upload_Link_Sent_At__c` is now history-tracked); missing email → "Dealer email seems to be missing…".
  RMR permission required. History rows aren't written in Apex tests (`sentHistoryStub`).
- **Sender:** Org-Wide Email Address "Harbor Motors Support" (abhishek.dutta@cloudkaptan.com, verified), set in
  `DNAMS_Pipeline_Setting__mdt.SenderEmailAddress__c`, applied by `DNAMSEmailSender` to all DNAMS emails (skips it if
  unverified).
- **Dealer site:** every element of the package gets an upload button. Package page: Elements list without Sort Order
  (sorted by Element Number); `Element_Narrative__c` label "Reason(s)"; Demo Scenario hidden; extra fields hidden in
  create mode via visibility rule `Record.Name CONTAINS DNAP-`.
- **Guest upload gotchas (cost a day):** lightning-file-upload on LWR as guest needs (1) site preference "Allow guest
  users to access public APIs" (Network `enableGuestChatter`), else 401 on `connect/file/upload/config`; (2) "Let guest
  users view asset files, library files, and CMS content" (`enableGuestFileAccess`), else 403
  INSUFFICIENT_ACCESS_OR_READONLY on `connect/files/users/me` before any Apex runs; (3) guest profile Edit on
  `ContentVersion.DNAMS_Upload_Token_fileupload__c`. A Metadata API retrieve of the guest profile MISREPORTS (3) as
  no access — never retrieve-and-redeploy that profile without fixing that line (the 2026-11-05 full deploy broke it).
  `DNAMS_GuestAccessTest` inserts the file as admin, so it can't catch these. Reproduce with real Chrome (Playwright,
  incognito) instead.
- Apex test gotcha: an unset checkbox on a new sObject reads false in Apex even when its default is true — re-query.
- **Guest submit must publish in system mode (2026-11-10, DNAP-0003904):** on API 67+ `EventBus.publish` runs in user
  mode; the guest profile has no Create on `DNAMS_Package_Review_Requested__e`, so a dealer's submit published nothing
  (SaveResult ignored, no run, no error). `EventBus.publish` has **no AccessLevel overload** (`publish(list, AccessLevel)`
  compiles as the callback overload and throws at runtime). Fix: `DNAMSReviewRequestPublisher` (API **66.0**, system
  mode) publishes; `DNAMS_PackageService.publishReviewRequests` rejects the submit (`addError`) if a publish fails.
  Regression test `DNAMS_GuestSubmitReviewTest` (runs as the real site guest, no files).

## Package status lifecycle (2026-11-09)
Supersedes the earlier "RMR Pending / Under Review after a run" notes. Picklist order (drives the Path): Draft, Initiated,
Dealer Submitted, RMR Pending, Under Review, Review Failed, Review Passed, Returned, Dealer Executed, Closed.
Constants in `DNAMS_PackageReviewPipelineService`: `PACKAGE_UNDER_REVIEW`, `PACKAGE_RMR_PENDING`, `PACKAGE_REVIEW_FAILED`,
`PACKAGE_REVIEW_PASSED`.
- **Run starts** (any source; `handleReviewRequests` creates a Running run) → **Under Review**. A Discarded run changes nothing.
- **Cancel** (`cancelActiveRun`, when a Running run is found) → **RMR Pending** at once. Later steps stop at `lockRun`,
  and `failRun` only touches the package when the run was still Running, so nothing overwrites it.
- **Run fails** → **Review Failed**: pre-flight gate (`DNAMSFilePreflightHelper.stopRun`), classification issues
  (`completeClassification`), extraction failure/timeout (`DNAMSExtractionCompletionHelper.applyOutcome`), any crash via
  `failRun` (classification batch/starter, `DNAMSErrorLogHelper.logException`, `DNAMSRuleUtil.failStage`/finalizer), rule
  validation Amber or Red (`DNAMSRuleValidationCompletionHelper`). Health is unchanged by this work.
- **Run passes**: classification pass and rule validation GREEN keep **Under Review** while narrative + transmittal drafting
  run; `DNAMSTransmittalStarterQueueable.completeRun` (run Completed/Passed, also when drafting failed) → **Review Passed**.
- RMR Pending is no longer a run outcome. Re-run / Return are allowed from Dealer Submitted, Under Review, Review Failed,
  Review Passed and RMR Pending (no active run).
- Record page banners: AI review in progress = Dealer Submitted or Under Review; Issues found = Review Failed + Red;
  Review needed = Review Failed + Amber; Review stopped = Review Failed + Health neither Red nor Amber (crash);
  All checks passed = Review Passed + Green; Review cancelled = RMR Pending; Returned; Waiting for dealer = Initiated.
- The path assistant has no per-step config, so it follows the picklist order automatically.
- Known gap (unchanged): if the GREEN narrative or transmittal job cannot be queued, the run stays Running and the
  package stays Under Review until the RMR cancels.

## Re-run changes only (2026-11-10)
Contract/details: `DNAMSRunChangeDetector` ApexDoc. RMR **Re-run** offers two modes; a Changes Only run compares with a
**baseline** = the package's last non-Discarded run (any status; unfinished stages of a Cancelled/Failed baseline re-run).
- **Modes:** `DNAMS_Package_Review_Requested__e.Mode__c` → run `RerunMode__c` (All / Changes Only; blank = All, so dealer
  submit/resubmit are always All). `requestRerun(Id, String mode)`; Changes Only with no earlier run falls back to All.
- **New fields:** Run `RerunMode__c`, `BaselineRun__c` (Changes Only only), `ChangeSummary__c` (long text); Stage result
  `ReusedFromResult__c` (blank = produced in this run; always points at the ORIGIN row, also across chained runs);
  event `Mode__c`.
- **Per-stage reuse** (a reused unit = `cloneForReuse` copy of the baseline row into the new run):
  - Pre-flight: always re-checked (no AI).
  - Classification: key element + ContentDocument + latest version; finished rows (any answer, not Error) reused without a
    model call — the stored raw answer is re-applied with the CURRENT confidence bands / accepted types, and the element
    result (required types, narrative) is rebuilt from all its files.
  - Extraction: key file + same document type + same IDP action name/id/version and a Passed schema; otherwise
    resubmitted (stub/live). All reused → straight to `completeExtraction` (re-validates against current ExpectedStructure).
  - Rules: values always resolved fresh; ExactMatch and PIR always evaluated; AIMatch reused only when Source/Reference
    values are identical (case-sensitive) and the model answered before.
  - AI Summary (narrative) and Transmittal: kept when `summaryNeeded` is false (no Classification/Extraction/AIMatch unit
    re-ran, same file/rule sets, same verdicts, same `Issue_Summary__c` — the last also covers two pre-flight stops);
    otherwise redrafted. Owner email skipped when kept and the result is unchanged. **Draft AI Transmittal** is unaffected.
- **Re-run modal** (flow `DNAMS_Rerun_Review` → `DNAMS_ReviewActionCheck` → `DNAMS_RmrReviewService.checkAction`): shows
  `DNAMSRunChangeDetector.preview` text; with changes the mode radio offers Re-run all / Re-run changes only, without
  changes only Re-run all ("Nothing has changed since RUN-x. Use Re-run all to run everything again."). `rerunReview(pkg,
  mode)` re-checks the preview server-side and refuses Changes Only when nothing changed. Preview detects file changes,
  IDP action/version changes and record/PIR value changes (re-resolves rules on the baseline extraction); ~8–16 SOQL.
- **ChangeSummary format:** line 1 `Compared with RUN-x (Status).`, then one line per stage, e.g.
  `Classification: 4 reused, 1 re-run (Org Chart / file.pdf: new version)`,
  `Rule Validation: 5 reused, 1 re-checked (AV_V04: values changed), 23 exact/PIR evaluated`,
  `AI Summary: kept from RUN-x (nothing changed)` / `written again (results changed)`, same for `Transmittal Drafting`.
- **Live E2E (Stub IDP), package DNAP-0003761 (`Demo_Scenario__c` "CDC E2E…", Ridgeline Northstar):** baseline RUN-004162
  Passed/Green 100% (5 files, 29 rules). Nothing changed → blocked, no run. New version of Org Chart (same bytes) →
  RUN-004163: 4/5 classification + 4/5 extraction + 6/6 AIMatch reused, same verdicts; All run RUN-004164 identical rule
  values/verdicts and consolidated extraction. Account BillingStreet edit → RUN-004165: only AV_V04 re-checked (restored
  afterwards; RUN-004166 re-checked it back).
- **Gotchas:**
  - Files are locked after submit, so a new version normally arrives via Return → dealer upload → resubmit (an All run).
    The E2E briefly set the package to Returned to add a version.
  - `CallbackToken__c` / `MuleSoftExecutionId__c` are unique: `cloneForReuse` clears them (and the callback payload/time),
    so reused extraction rows are terminal and never touched by the submit batch, callback API or cleanup job.
  - Tests: "No more than one executeBatch can be called from within a test method" when a Changes Only flow chains the
    classification batch into another batch — stop the chain or call stages directly. Parallel `sf apex run test`
    calls fail with ALREADY_IN_PROCESS; run test classes in one call or wait.
  - `ReviewRun__c` is master-detail (not reparentable): never move a reused row; insert a copy.
  - Org limit `ContentPublicationLimit` = **2,500 ContentVersion inserts per rolling 24 h, and Apex tests count**. Several
    full DNAMS* runs in one day exhaust it → ~90 file-based tests fail with "ContentPublication Limit exceeded" (not a
    code failure). Check `sf org list limits -o DNAMS_SDO` first; run the affected classes only, later.

## Dealer portal redesign (2026-11-10)
- `dnamsPackageUpload` rebuilt from the approved mock (Claude artifact "Harbor Motors Dealer Portal", user's own mock
  file as the base): navy band with the page headline, bordered package card with the element table, right column
  with a "Completed"/"Corrections" progress ring and Steps 1–2 only, footer. `dnamsBrandHeader` restyled to match
  (white bar, teal underline). No narrative/AI summary on the dealer page any more; issues are the element narratives.
- Table: Element (name, info tooltip with instructions, file count) | Files | standard `lightning-file-upload`
  (`accept=.pdf`, multiple). No status column; the left edge colour shows state. Files are two equal cards per line
  (max 250px each) in a fixed-height area (96px) that scrolls. Guest uploads must stay on lightning-file-upload
  (a guest Apex ContentVersion insert fails), so the custom "Upload" button from the mock is not used.
- Returned: only elements with an issue are listed; uploading/removing marks one "Updated" (client-side only).
- Submit: own confirm modal "Are you sure you want to submit the package? This link closes after you submit."
- **Link closes after submit:** `DNAMS_GuestUploadController.getPackage` returns `isClosed = true` and no elements for
  any non-editable status; the page shows "Thank you / Your package has been received."
- **New link on return:** `DNAMS_RmrReviewService.returnToDealer` writes a new `Upload_Token__c`
  (`DNAMS_PackageService.newUploadToken`, now public) in system mode (the field is read-only for users) before the email.
- Tests: `DNAMS_PackageServiceTest.guestUploadsThenSubmits` (closed view), `DNAMS_RmrReviewTest.returnToDealer…`
  (new token, old link invalid). 39/39 pass across PackageService, RmrReview, GuestAccess, GuestSubmitReview.
- PDF-only is enforced in the browser only (`accept`), not by the ContentVersion trigger.
