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

- Every active Element Type is added to every new package (any package type). Changes to types affect only
  packages created afterwards.
- `DNAMS_Package_Type_Element__c` (per-package-type mapping) existed in slice 1 and was **deleted** in slice 2
  at the user's request.
- `Type__c` uses Global Value Set `DNAMS_Package_Type`: Buy/Sell change of Ownership, Term Renewal, Dealer
  Principal Change. `Status__c`: Draft (default), Initiated, Dealer Submitted, RMR Pending, Under Review,
  Returned, Dealer Executed, Closed.
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

## Next (not started)
- PIR status in the RMR email (definition needed from the user).
- Step 23: the extraction design (spec needed).
- The golden test set (G8.05) and review of the 22 identifying definitions.
- Review timeout / escalation (G1.15) if wanted.

## Rule validation (2026-11-04) — rule validation diagram steps 1–23 (built on top of Abhishek's extraction branch)
- Rules: `DNAMSRule__mdt` (30 records, source of truth `rule_validation/DNAMSRules.json`; DeveloperName = rule id, e.g.
  `DA_V01`). Keys: `extraction.<IDP action>.<field>` (top-level fields only), `Package.<lookup>__r[.<rel>].<field>`
  (≤3 levels), Static literals / JSON lists, `{TODAY-n}`. User asked: no `[*]`, filters or `sum()`.
- Flow: extraction completion → `DNAMSRuleValidationStarterQueueable` (rules + PIR, ExactMatch in `DNAMSRuleEvaluator`)
  → `DNAMSAIRuleValidationQueueable` (AIMatch, prompt `DNAMS_RuleValidation_Prompt`, ≤50 per call, retries → CANNOT_DECIDE)
  → `DNAMSRuleValidationCompletionHelper` (pass rate excl. NOT_APPLICABLE; 100% Green / ≥85% Amber / else Red; failed
  PIR → Red). Green: package Under Review, owner email, run stays Running → `DNAMSTransmittalStarterQueueable`
  (placeholder, completes Passed). Amber/Red: package RMR Pending, run Completed/Needs Review, narrative + email.
- Results: one `AIReviewStageResult__c` per rule (`Stage__c` Rule Validation; RuleId/RuleName/ComparisonMethod/
  SourceValue/ReferenceValue/Verdict). Run: `RuleValidationProcessingStatus__c` + 3 pass-rate fields. Package
  `Health__c` gained Amber; PIR checkboxes `PIR_Linked__c`, `PIR_Cleared__c`, `PIR_Bypass_Acknowledged__c`,
  `PIR_Bypass_Reason__c`; settings `PIRRequiredPackageTypes__c` (Buy/Sell; Dealer Principal Change),
  `RuleValidationBatchSize__c`, `RuleValidationPromptTemplate__c`.
- Tests: `DNAMSRuleValidationTest` (10). Deploy only changed paths: `sf project deploy start -d force-app` would
  overwrite the two profiles that differ in the org, and this org runs **no tests on deploy/validate** — run
  `sf apex run test` afterwards.
- Not yet verified live: AIMatch prompt call as the IDP integration user (needs Einstein access).
