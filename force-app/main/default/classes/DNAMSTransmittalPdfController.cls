/**
 * @description     Generates the Dealer Transmittal PDF (Visualforce page DNAMS_TransmittalPdf, renderAs pdf) for a
 *                  DNAMS_Package__c and backs the Generate Transmittal quick action (LWC dnamsGenerateTransmittal).
 *                  The PDF is only produced when the package is ready: the latest non-discarded review run Completed and
 *                  Passed with every stage Completed, both transmittal summaries drafted, and the Dealer Application
 *                  extraction present. Nothing is saved in Salesforce; the page streams the PDF as a download.
 *                  The package is read in user mode (sharing and field access of the RMR); the run is read in system
 *                  mode because the RMR may not own the run (same approach as DNAMSTransmittalController).
 *                  SSN, EIN and date of birth from the extraction are never read into the view.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-10
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-10   Abhishek Dutta  Initial version
 **/
@SuppressWarnings('PMD.ExcessivePublicCount, PMD.CyclomaticComplexity')
public with sharing class DNAMSTransmittalPdfController {
    public static final String MESSAGE_NO_ACCESS = 'You do not have access to this package.';
    public static final String MESSAGE_NO_RUN = 'No review has been run for this package yet.';
    public static final String MESSAGE_RUNNING = 'The AI review {0} is still running.';
    public static final String MESSAGE_CANCELLED = 'The latest review {0} was cancelled.';
    public static final String MESSAGE_NOT_PASSED = 'The latest review {0} did not pass{1}. All review stages must pass before a transmittal can be generated.';
    public static final String MESSAGE_DRAFTING = 'The transmittal summaries are still being drafted.';
    public static final String MESSAGE_SUMMARY_MISSING = 'The {0} has not been drafted yet. Use Draft AI Transmittal first.';
    public static final String MESSAGE_SUMMARIES_MISSING =
        'The Ownership Summary and Executive Summary have not been drafted yet. Use Draft AI Transmittal first.';
    public static final String MESSAGE_NO_DEALER_APPLICATION = 'The Dealer Application extraction is missing from review {0}.';
    public static final String MESSAGE_STATUS = 'The package status is {0}. It must be Review Passed.';
    public static final String MESSAGE_UNEXPECTED = 'Something went wrong with the transmittal. Please try again or contact your administrator.';

    public static final String PREPARER_TITLE = 'Regional Market Representative';
    public static final String DASH = '–';

    private static final String CLASS_NAME = DNAMSTransmittalPdfController.class.getName();
    private static final String DATE_FORMAT = 'dd MMMM yyyy';
    private static final String DEALER_APPLICATION_KEY = 'DealerApplication';
    private static final String SUMMARY_OWNERSHIP = 'Ownership Summary';
    private static final String SUMMARY_EXECUTIVE = 'Executive Summary';
    // Statuses in which a transmittal can be (re)generated once the review has passed
    private static final Set<String> READY_PACKAGE_STATUSES = new Set<String>{
        DNAMS_PackageReviewPipelineService.PACKAGE_REVIEW_PASSED,
        'Dealer Executed',
        'Closed'
    };
    private static final Set<String> DRAFTING_STATUSES = new Set<String>{
        DNAMSPipelineConstants.RUN_STAGE_PENDING,
        DNAMSPipelineConstants.RUN_STAGE_IN_PROGRESS
    };

    /** @description Whether the PDF is rendered (false renders the issue list as plain HTML). */
    public Boolean ready { get; private set; }
    /** @description Unmet readiness items, shown instead of the document. */
    public List<String> issues { get; private set; }
    /** @description Document reference, also used by the page footer. */
    public String reference { get; private set; }
    /** @description The document view model (null when not ready). */
    public TransmittalView view { get; private set; }

    /**
     * @description Result of the readiness check for the quick action.
     **/
    public class Readiness {
        @AuraEnabled
        public Boolean ready;
        @AuraEnabled
        public List<String> issues;
        @AuraEnabled
        public String downloadUrl;
    }

    /**
     * @description One row of the owners table.
     **/
    public class OwnerRow {
        public String name { get; set; }
        public String ownerType { get; set; }
        public String heldThrough { get; set; }
        public String ownership { get; set; }
        public String voting { get; set; }
    }

    /**
     * @description Everything the document shows. Values are plain text; the page escapes them on output.
     **/
    @SuppressWarnings('PMD.TooManyFields')
    public class TransmittalView {
        // Title, control block and at a glance
        public String packageNumber { get; set; }
        public String packageName { get; set; }
        public String packageType { get; set; }
        public String dealerName { get; set; }
        public String dealerCode { get; set; }
        public String preparedOn { get; set; }
        public String preparedBy { get; set; }
        public String preparerTitle { get; set; }
        public String overallResult { get; set; }
        public String health { get; set; }
        public String checksPassed { get; set; }
        // Package details
        public String sellingDealerName { get; set; }
        public String contactName { get; set; }
        public String contactEmail { get; set; }
        public String runName { get; set; }
        public String runCompletedOn { get; set; }
        // Summaries
        public List<String> executiveParagraphs { get; set; }
        public List<String> ownershipParagraphs { get; set; }
        // Dealer profile (Dealer Application extraction)
        public String legalName { get; set; }
        public String tradeName { get; set; }
        public String applicationDealerCode { get; set; }
        public String region { get; set; }
        public String street { get; set; }
        public String cityStateZip { get; set; }
        public String licence { get; set; }
        public String operatorName { get; set; }
        public String operatorTitle { get; set; }
        public String officerName { get; set; }
        public String officerTitle { get; set; }
        public String signedOn { get; set; }
        public String bankruptcy { get; set; }
        public String conviction { get; set; }
        public List<OwnerRow> owners { get; set; }
    }

    /**
     * @description Package, latest run and Dealer Application data behind one readiness check.
     **/
    @TestVisible
    private class GateContext {
        DNAMS_Package__c pkg;
        AI_Package_Review_Run__c run;
        Map<String, Object> dealerApplication;
        List<String> issues = new List<String>();
    }

    /**
     * @description Page constructor: checks readiness for the `id` page parameter and, when ready, builds the view and
     *              sets the download file name. When not ready the page renders the issues instead of a PDF.
     **/
    public DNAMSTransmittalPdfController() {
        ready = false;
        reference = '';
        issues = new List<String>();
        try {
            Id packageId = toId(ApexPages.currentPage().getParameters().get('id'));
            GateContext context = evaluate(packageId);
            if (context == null) {
                issues.add(MESSAGE_NO_ACCESS);
                return;
            }
            issues = context.issues;
            if (!issues.isEmpty()) {
                return;
            }
            Datetime now = Datetime.now();
            view = buildView(context, now);
            reference = referenceFor(context.pkg.Name, now);
            ready = true;
            ApexPages.currentPage()
                .getHeaders()
                .put('Content-Disposition', 'attachment; filename=Dealer_Transmittal_' + context.pkg.Name + '.pdf');
        } catch (Exception e) {
            DNAMSErrorLogHelper.logException(e, null, CLASS_NAME);
            ready = false;
            view = null;
            issues = new List<String>{ MESSAGE_UNEXPECTED };
        }
    }

    /**
     * @description Readiness check for the Generate Transmittal quick action.
     * @param packageId DNAMS_Package__c id
     * @return ready, every unmet item and the PDF download URL
     * @example
     *   DNAMSTransmittalPdfController.Readiness readiness = DNAMSTransmittalPdfController.getReadiness(packageId);
     **/
    @AuraEnabled
    public static Readiness getReadiness(Id packageId) {
        GateContext context;
        try {
            context = evaluate(packageId);
        } catch (Exception e) {
            DNAMSErrorLogHelper.logException(e, null, CLASS_NAME);
            throw auraError(MESSAGE_UNEXPECTED);
        }
        if (context == null) {
            throw auraError(MESSAGE_NO_ACCESS);
        }
        Readiness readiness = new Readiness();
        readiness.issues = context.issues;
        readiness.ready = context.issues.isEmpty();
        if (readiness.ready) {
            PageReference pdfPage = Page.DNAMS_TransmittalPdf;
            pdfPage.getParameters().put('id', packageId);
            readiness.downloadUrl = pdfPage.getUrl();
        }
        return readiness;
    }

    /**
     * @description Loads the package (user mode) and its latest non-discarded run (system mode) and lists every unmet
     *              readiness item.
     * @param packageId DNAMS_Package__c id
     * @return The context, or null when the package is not visible to the running user
     **/
    @TestVisible
    private static GateContext evaluate(Id packageId) {
        if (packageId == null) {
            return null;
        }
        List<DNAMS_Package__c> packages = [
            SELECT
                Id,
                Name,
                Package_Name__c,
                Type__c,
                Status__c,
                Health__c,
                Buying_Dealer__r.Name,
                Buying_Dealer__r.AccountNumber,
                Selling_Dealer__r.Name,
                Primary_Contact__r.Name,
                Primary_Contact__r.Email,
                Ownership_Summary__c,
                Executive_Summary__c
            FROM DNAMS_Package__c
            WHERE Id = :packageId
            WITH USER_MODE
            LIMIT 1
        ];
        if (packages.isEmpty()) {
            return null;
        }
        GateContext context = new GateContext();
        context.pkg = packages[0];
        List<AI_Package_Review_Run__c> runs = [
            SELECT
                Id,
                Name,
                Status__c,
                Overall_Result__c,
                Ended_At__c,
                RuleValidationPassRate__c,
                Classification_Processing_Status__c,
                ExtractionProcessingStatus__c,
                RuleValidationProcessingStatus__c,
                TransmittalProcessingStatus__c,
                ConsolidatedExtractionJSON__c
            FROM AI_Package_Review_Run__c
            WHERE Package__c = :packageId AND Status__c != :DNAMS_PackageReviewPipelineService.RUN_DISCARDED
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
        ];
        context.run = runs.isEmpty() ? null : runs[0];
        addRunIssues(context);
        addSummaryIssues(context);
        // A running review has no extraction yet, so the Dealer Application is only checked once the run has ended
        if (context.run != null && !DNAMS_PackageReviewPipelineService.ACTIVE_RUN_STATUSES.contains(context.run.Status__c)) {
            context.dealerApplication = dealerApplication(context.run.ConsolidatedExtractionJSON__c);
            if (context.dealerApplication == null) {
                context.issues.add(String.format(MESSAGE_NO_DEALER_APPLICATION, new List<Object>{ context.run.Name }));
            }
        }
        return context;
    }

    /**
     * @description Adds the run issues: no run, still running, cancelled, not passed, summaries still drafting, and the
     *              package status once the run itself has passed.
     * @param context The gate context
     **/
    private static void addRunIssues(GateContext context) {
        AI_Package_Review_Run__c run = context.run;
        if (run == null) {
            context.issues.add(MESSAGE_NO_RUN);
            return;
        }
        List<Object> runName = new List<Object>{ run.Name };
        if (DNAMS_PackageReviewPipelineService.ACTIVE_RUN_STATUSES.contains(run.Status__c)) {
            context.issues.add(String.format(MESSAGE_RUNNING, runName));
        } else if (run.Status__c == DNAMS_PackageReviewPipelineService.RUN_CANCELLED) {
            context.issues.add(String.format(MESSAGE_CANCELLED, runName));
        } else if (!hasPassed(run)) {
            context.issues.add(String.format(MESSAGE_NOT_PASSED, new List<Object>{ run.Name, notPassedDetail(context) }));
        } else if (DRAFTING_STATUSES.contains(run.TransmittalProcessingStatus__c)) {
            context.issues.add(MESSAGE_DRAFTING);
        } else if (!READY_PACKAGE_STATUSES.contains(context.pkg.Status__c)) {
            context.issues.add(String.format(MESSAGE_STATUS, new List<Object>{ context.pkg.Status__c }));
        }
    }

    /**
     * @description Whether the run Completed as Passed with classification, extraction and rule validation Completed.
     * @param run The run
     * @return true when every review stage passed
     **/
    private static Boolean hasPassed(AI_Package_Review_Run__c run) {
        String completed = DNAMSPipelineConstants.RUN_STAGE_COMPLETED;
        return run.Status__c == DNAMS_PackageReviewPipelineService.RUN_COMPLETED &&
            run.Overall_Result__c == DNAMS_PackageReviewPipelineService.RESULT_PASSED &&
            run.Classification_Processing_Status__c == completed &&
            run.ExtractionProcessingStatus__c == completed &&
            run.RuleValidationProcessingStatus__c == completed;
    }

    /**
     * @description " (Health Amber, rule validation 92%)" detail for the not-passed message; blank parts are left out.
     * @param context The gate context
     * @return The detail, or an empty string
     **/
    private static String notPassedDetail(GateContext context) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(context.pkg.Health__c)) {
            parts.add('Health ' + context.pkg.Health__c);
        }
        if (context.run.RuleValidationPassRate__c != null) {
            parts.add('rule validation ' + wholePercent(context.run.RuleValidationPassRate__c));
        }
        return parts.isEmpty() ? '' : ' (' + String.join(parts, ', ') + ')';
    }

    /**
     * @description Adds the issue for a missing Ownership and/or Executive summary.
     * @param context The gate context
     **/
    private static void addSummaryIssues(GateContext context) {
        Boolean ownershipMissing = toParagraphs(context.pkg.Ownership_Summary__c).isEmpty();
        Boolean executiveMissing = toParagraphs(context.pkg.Executive_Summary__c).isEmpty();
        if (ownershipMissing && executiveMissing) {
            context.issues.add(MESSAGE_SUMMARIES_MISSING);
        } else if (ownershipMissing || executiveMissing) {
            String missing = ownershipMissing ? SUMMARY_OWNERSHIP : SUMMARY_EXECUTIVE;
            context.issues.add(String.format(MESSAGE_SUMMARY_MISSING, new List<Object>{ missing }));
        }
    }

    /**
     * @description The first Dealer Application extraction's data map from the consolidated extraction JSON.
     * @param consolidatedJson AI_Package_Review_Run__c.ConsolidatedExtractionJSON__c
     * @return The data map, or null when missing or unreadable
     **/
    @TestVisible
    private static Map<String, Object> dealerApplication(String consolidatedJson) {
        if (String.isBlank(consolidatedJson)) {
            return null;
        }
        try {
            Object root = JSON.deserializeUntyped(consolidatedJson);
            if (!(root instanceof Map<String, Object>)) {
                return null;
            }
            Object entries = ((Map<String, Object>) root).get(DEALER_APPLICATION_KEY);
            if (!(entries instanceof List<Object>) || ((List<Object>) entries).isEmpty() || !(((List<Object>) entries)[0] instanceof Map<String, Object>)) {
                return null;
            }
            Object data = ((Map<String, Object>) ((List<Object>) entries)[0]).get('data');
            return data instanceof Map<String, Object> ? (Map<String, Object>) data : null;
        } catch (JSONException e) {
            return null;
        }
    }

    /**
     * @description Builds the document view model from a ready context.
     * @param context The gate context (no issues)
     * @param now     The preparation time
     * @return The view model
     **/
    @TestVisible
    private static TransmittalView buildView(GateContext context, Datetime now) {
        DNAMS_Package__c pkg = context.pkg;
        AI_Package_Review_Run__c run = context.run;
        TransmittalView view = new TransmittalView();
        view.packageNumber = pkg.Name;
        view.packageName = orDash(pkg.Package_Name__c);
        view.packageType = orDash(pkg.Type__c);
        view.dealerName = orDash(pkg.Buying_Dealer__r?.Name);
        view.dealerCode = orDash(pkg.Buying_Dealer__r?.AccountNumber);
        view.sellingDealerName = pkg.Selling_Dealer__r?.Name;
        view.contactName = orDash(pkg.Primary_Contact__r?.Name);
        view.contactEmail = pkg.Primary_Contact__r?.Email;
        view.preparedOn = now.format(DATE_FORMAT);
        view.preparedBy = UserInfo.getName();
        view.preparerTitle = PREPARER_TITLE;
        view.overallResult = orDash(run.Overall_Result__c);
        view.health = orDash(pkg.Health__c);
        view.checksPassed = run.RuleValidationPassRate__c == null ? DASH : wholePercent(run.RuleValidationPassRate__c);
        view.runName = run.Name;
        view.runCompletedOn = run.Ended_At__c == null ? DASH : run.Ended_At__c.format(DATE_FORMAT);
        view.executiveParagraphs = toParagraphs(pkg.Executive_Summary__c);
        view.ownershipParagraphs = toParagraphs(pkg.Ownership_Summary__c);
        addDealerProfile(view, context.dealerApplication);
        view.owners = ownerRows(context.dealerApplication);
        return view;
    }

    /**
     * @description Fills the dealer profile from the Dealer Application data (missing values become a dash).
     * @param view The view model
     * @param data The Dealer Application data map
     **/
    private static void addDealerProfile(TransmittalView view, Map<String, Object> data) {
        view.legalName = text(data, 'LegalNameOrDealerEntity');
        view.tradeName = text(data, 'TradeName');
        view.applicationDealerCode = text(data, 'DealerCode');
        view.region = text(data, 'RegionOrDistrict');
        view.street = text(data, 'DealershipStreetAddress');
        view.cityStateZip = cityStateZip(data);
        view.licence = text(data, 'StateDealerLicenseNumber');
        view.operatorName = text(data, 'DealerOperatorPrintedName');
        view.operatorTitle = rawText(data, 'DealerOperatorPrintedTitle');
        view.officerName = text(data, 'AuthorizedOfficerOfDealerEntityPrintedName');
        view.officerTitle = rawText(data, 'AuthorizedOfficerOfDealerEntityPrintedTitle');
        view.signedOn = text(data, 'DealerOperatorSigningDate');
        view.bankruptcy = yesNo(data, 'HasApplicantBeenBankrupt');
        view.conviction = yesNo(data, 'HasApplicantBeenConvicted');
    }

    /**
     * @description Direct owners (ownership and voting %) followed by indirect owners (held through, effective %).
     *              SSN, EIN and date of birth are never read.
     * @param data The Dealer Application data map
     * @return The owner rows
     **/
    private static List<OwnerRow> ownerRows(Map<String, Object> data) {
        List<OwnerRow> rows = new List<OwnerRow>();
        for (Map<String, Object> owner : listOfMaps(data, 'OwnershipInfoDirectOwners')) {
            OwnerRow row = new OwnerRow();
            row.name = text(owner, 'NameOfOwner');
            row.ownerType = 'Direct';
            row.heldThrough = DASH;
            row.ownership = percent(owner, 'OwnershipPercentage');
            row.voting = percent(owner, 'VotingPercentage');
            rows.add(row);
        }
        for (Map<String, Object> owner : listOfMaps(data, 'OwnershipInfoIndirectOwners')) {
            OwnerRow row = new OwnerRow();
            row.name = text(owner, 'Name');
            row.ownerType = 'Indirect';
            row.heldThrough = text(owner, 'HeldThrough');
            row.ownership = percent(owner, 'EffectivePercentageOfDealer');
            row.voting = DASH;
            rows.add(row);
        }
        return rows;
    }

    /**
     * @description The map entries of a JSON list under a key (non-map entries are skipped).
     * @param data The map
     * @param key  The list key
     * @return The maps, empty when missing
     **/
    private static List<Map<String, Object>> listOfMaps(Map<String, Object> data, String key) {
        List<Map<String, Object>> maps = new List<Map<String, Object>>();
        Object value = data?.get(key);
        if (value instanceof List<Object>) {
            for (Object entry : (List<Object>) value) {
                if (entry instanceof Map<String, Object>) {
                    maps.add((Map<String, Object>) entry);
                }
            }
        }
        return maps;
    }

    /**
     * @description "City, ST 12345" from the dealership address parts, or a dash when all are missing.
     * @param data The Dealer Application data map
     * @return The line
     **/
    private static String cityStateZip(Map<String, Object> data) {
        String city = rawText(data, 'DealershipCity');
        String stateZip = String.join(nonBlank(new List<String>{ rawText(data, 'DealershipState'), rawText(data, 'DealershipZip') }), ' ');
        String line = String.join(nonBlank(new List<String>{ city, stateZip }), ', ');
        return String.isBlank(line) ? DASH : line;
    }

    /**
     * @description The non-blank values of a list.
     * @param values The values
     * @return The non-blank values in order
     **/
    private static List<String> nonBlank(List<String> values) {
        List<String> kept = new List<String>();
        for (String value : values) {
            if (String.isNotBlank(value)) {
                kept.add(value);
            }
        }
        return kept;
    }

    /**
     * @description A JSON value as trimmed text, or null when missing or blank.
     * @param data The map
     * @param key  The key
     * @return The text or null
     **/
    private static String rawText(Map<String, Object> data, String key) {
        Object value = data?.get(key);
        String textValue = value == null ? null : String.valueOf(value).trim();
        return String.isBlank(textValue) ? null : textValue;
    }

    /**
     * @description A JSON value as text, or a dash when missing.
     * @param data The map
     * @param key  The key
     * @return The text or a dash
     **/
    private static String text(Map<String, Object> data, String key) {
        return orDash(rawText(data, key));
    }

    /**
     * @description "Yes" for true/yes, "No" otherwise, a dash when missing.
     * @param data The map
     * @param key  The key
     * @return Yes, No or a dash
     **/
    private static String yesNo(Map<String, Object> data, String key) {
        String value = rawText(data, key);
        if (value == null) {
            return DASH;
        }
        return value.equalsIgnoreCase('true') || value.equalsIgnoreCase('yes') ? 'Yes' : 'No';
    }

    /**
     * @description A percentage without trailing zeros ("60.00" becomes "60%"); non-numeric values are shown as given.
     * @param data The map
     * @param key  The key
     * @return The percentage or a dash
     **/
    private static String percent(Map<String, Object> data, String key) {
        String value = rawText(data, key);
        if (value == null) {
            return DASH;
        }
        try {
            return Decimal.valueOf(value.removeEnd('%').trim()).stripTrailingZeros().toPlainString() + '%';
        } catch (TypeException e) {
            return value;
        }
    }

    /**
     * @description A pass rate as a whole percentage, rounded down so that 100% always means every check passed.
     * @param rate The rate (0-100)
     * @return For example "92%"
     **/
    private static String wholePercent(Decimal rate) {
        return String.valueOf(rate.setScale(0, System.RoundingMode.DOWN)) + '%';
    }

    /**
     * @description The value, or a dash when blank.
     * @param value The value
     * @return The value or a dash
     **/
    private static String orDash(String value) {
        return String.isBlank(value) ? DASH : value;
    }

    /**
     * @description Splits a rich-text summary into plain-text paragraphs. Line breaks and block ends separate
     *              paragraphs, any other markup is dropped and entities are decoded, so the page can escape the text
     *              once on output (no double escaping, no raw HTML).
     * @param richText The rich-text summary
     * @return The non-blank paragraphs
     **/
    @TestVisible
    private static List<String> toParagraphs(String richText) {
        List<String> paragraphs = new List<String>();
        if (String.isBlank(richText)) {
            return paragraphs;
        }
        String plain = richText.replaceAll('(?i)<br\\s*/?>|</p>|</div>|</li>', '\n').replaceAll('<[^>]*>', '').unescapeHtml4();
        for (String line : plain.split('\n')) {
            if (String.isNotBlank(line)) {
                paragraphs.add(line.trim());
            }
        }
        return paragraphs;
    }

    /**
     * @description Document reference TR-<package number digits>-<yymmdd>.
     * @param packageNumber Package Name (e.g. DNAP-0003761)
     * @param now           The preparation time
     * @return The reference
     **/
    @TestVisible
    private static String referenceFor(String packageNumber, Datetime now) {
        return 'TR-' + packageNumber.substringAfterLast('-') + '-' + now.format('yyMMdd');
    }

    /**
     * @description Parses an id parameter.
     * @param value The parameter value
     * @return The id, or null when blank or invalid
     **/
    private static Id toId(String value) {
        try {
            return String.isBlank(value) ? null : Id.valueOf(value);
        } catch (StringException e) {
            return null;
        }
    }

    /**
     * @description Builds an AuraHandledException whose message is readable by Apex callers and the LWC.
     * @param message The user-facing message
     * @return The exception to throw
     **/
    private static AuraHandledException auraError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
