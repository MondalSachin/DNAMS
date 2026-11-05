/**
 * Diagram steps 18-20 (and rule validation steps 19-21): writes the structured AI summary of a run onto the package,
 * then applies the owner check (19) and emails the owner (20).
 * The narrator prompt gets a JSON of facts (package, element stage results, rules that did not pass) and must return
 * one fixed JSON shape: {headline, overall_health, summary, elements[{element, status, findings[]}],
 * next_steps[]} (findings are plain sentences quoting the compared values). The answer is validated and normalised here; if the model fails or answers out of shape, the same
 * structure is built from the facts without AI. Package.AI_Narrative_JSON__c holds the structure (rendered by
 * dnamsAiSummaryView on the record page and the dealer page) and AI_Narrative__c the plain-text version (emails).
 * overall_health always comes from the package's Health__c, never from the model.
 */
public without sharing class DNAMS_PackageNarrativeQueueable implements Queueable, Database.AllowsCallouts {
    public static final String AI_LABEL = 'AI-generated summary - verify before acting.';
    private static final Integer TEXT_LENGTH = 32768;
    private static final Integer MAX_ITEMS = 5;
    private static final Set<String> ELEMENT_STATUSES = new Set<String>{ 'PASSED', 'NEEDS_REVIEW', 'FAILED', 'MISSING' };

    @TestVisible
    private static DNAMS_NarrativeWriter writer = new DNAMS_EinsteinNarrativeWriter();

    private final Id runId;
    private final String subjectSuffix;
    private final Queueable next;

    public DNAMS_PackageNarrativeQueueable(Id runId) {
        this(runId, 'document review found issues', null);
    }

    // Rule validation passes its RAG band in the subject (diagram rule validation step 21).
    public DNAMS_PackageNarrativeQueueable(Id runId, String subjectSuffix) {
        this(runId, subjectSuffix, null);
    }

    // next: a job to queue after the summary is written (GREEN: transmittal drafting).
    public DNAMS_PackageNarrativeQueueable(Id runId, String subjectSuffix, Queueable next) {
        this.runId = runId;
        this.subjectSuffix = subjectSuffix;
        this.next = next;
    }

    public void execute(QueueableContext context) {
        AI_Package_Review_Run__c run = [SELECT Id, Package__c, Issue_Summary__c, Reason__c FROM AI_Package_Review_Run__c WHERE Id = :runId];
        Map<String, Object> facts = buildFacts(runId);
        String factsJson = JSON.serialize(facts);

        // Model call first: callouts are not allowed after uncommitted DML.
        Map<String, Object> summary;
        String note;
        try {
            summary = parseSummary(writer.write(DNAMS_PackageReviewPipelineService.settings().Narrative_Prompt_Template__c, factsJson));
        } catch (Exception e) {
            note = 'Narrative fell back to the rule-based summary: ' + e.getTypeName() + ': ' + e.getMessage();
            summary = fallbackSummary(facts);
        }
        summary.put('overall_health', facts.get('overall_health'));
        String plain = toPlainText(summary);

        update new DNAMS_Package__c(
            Id = run.Package__c,
            AI_Narrative__c = plain.left(TEXT_LENGTH),
            AI_Narrative_JSON__c = JSON.serialize(summary).left(TEXT_LENGTH)
        );
        AI_Package_Review_Run__c runUpdate = new AI_Package_Review_Run__c(Id = runId, Narrative_Input__c = factsJson.left(131072));
        if (note != null) {
            runUpdate.Error__c = note.left(TEXT_LENGTH);
        }
        update runUpdate;

        DNAMS_PackageReviewPipelineService.notifyOwners(
            new Map<Id, AI_Package_Review_Run__c>{ run.Package__c => run },
            subjectSuffix,
            AI_LABEL + '\n\n' + plain
        );
        if (next != null) {
            String notQueued = DNAMSRuleUtil.tryEnqueue(next);
            if (notQueued != null) {
                AI_Package_Review_Run__c failed = new AI_Package_Review_Run__c(Id = runId, Error__c = ('The next job was not queued: ' + notQueued).left(TEXT_LENGTH));
                if (next instanceof DNAMSTransmittalStarterQueueable) {
                    // No job will draft: free the Draft AI Transmittal button for the RMR
                    failed.TransmittalProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_FAILED;
                }
                update failed;
            }
        }
    }

    /**
     * Facts for the prompt: the package, every element that is required or has a result, and the rules that did not
     * pass. Contains no extracted personal data (rule reasoning is written without it).
     */
    @TestVisible
    private static Map<String, Object> buildFacts(Id runId) {
        AI_Package_Review_Run__c run = [
            SELECT Id, Name, Issue_Summary__c, Overall_Result__c, RuleValidationPassRate__c, Package__c, Package__r.Name,
                Package__r.Package_Name__c, Package__r.Type__c, Package__r.Health__c, Package__r.Status__c
            FROM AI_Package_Review_Run__c
            WHERE Id = :runId
        ];
        Map<String, String> descriptions = new Map<String, String>();
        for (DNAMSRule__mdt rule : DNAMSRuleUtil.getRules()) {
            descriptions.put(rule.DeveloperName, rule.Description__c);
        }
        Map<Id, List<Object>> rulesByElement = new Map<Id, List<Object>>();
        List<Object> packageRules = new List<Object>();
        Integer passed = 0;
        Integer notPassed = 0;
        for (AIReviewStageResult__c row : [
            SELECT RuleId__c, RuleName__c, Verdict__c, Reasoning__c, SourceValue__c, ReferenceValue__c, PackageElement__c
            FROM AIReviewStageResult__c
            WHERE ReviewRun__c = :runId AND Stage__c = 'Rule Validation' AND Verdict__c != null
        ]) {
            if (row.Verdict__c == 'PASS') {
                passed++;
                continue;
            }
            if (row.Verdict__c == 'NOT_APPLICABLE') {
                continue;
            }
            notPassed++;
            Map<String, Object> rule = new Map<String, Object>{
                'rule' => row.RuleName__c,
                'checks' => descriptions.get(row.RuleId__c),
                'verdict' => row.Verdict__c == 'FAIL' ? 'did not match' : 'could not be confirmed',
                'value_on_document' => (row.SourceValue__c ?? '').normalizeSpace().left(200),
                'value_expected' => (row.ReferenceValue__c ?? '').normalizeSpace().left(200),
                'reason' => (row.Reasoning__c ?? '').normalizeSpace().left(300)
            };
            if (row.PackageElement__c == null) {
                packageRules.add(rule);
            } else {
                if (!rulesByElement.containsKey(row.PackageElement__c)) {
                    rulesByElement.put(row.PackageElement__c, new List<Object>());
                }
                rulesByElement.get(row.PackageElement__c).add(rule);
            }
        }

        Set<Id> withFiles = new Set<Id>();
        Map<Id, DNAMS_Package_Element__c> elements = new Map<Id, DNAMS_Package_Element__c>([
            SELECT Id, Name, Is_Required__c, Classification_Status__c, Extraction_Status__c, Rule_Validation_Status__c,
                Element_Narrative__c, Classified_As__c
            FROM DNAMS_Package_Element__c
            WHERE Package__c = :run.Package__c
            ORDER BY Sort_Order__c ASC NULLS LAST, Name
        ]);
        if (!elements.isEmpty()) {
            for (ContentDocumentLink link : [SELECT LinkedEntityId FROM ContentDocumentLink WHERE LinkedEntityId IN :elements.keySet()]) {
                withFiles.add(link.LinkedEntityId);
            }
        }
        List<Object> elementFacts = new List<Object>();
        for (DNAMS_Package_Element__c element : elements.values()) {
            Boolean hasResult = element.Classification_Status__c != null || String.isNotBlank(element.Element_Narrative__c) || rulesByElement.containsKey(element.Id);
            if (!element.Is_Required__c && !withFiles.contains(element.Id) && !hasResult) {
                continue;
            }
            elementFacts.add(new Map<String, Object>{
                'element' => element.Name,
                'required' => element.Is_Required__c,
                'has_document' => withFiles.contains(element.Id),
                'status' => elementStatus(element, withFiles.contains(element.Id)),
                'classification' => element.Classification_Status__c,
                'classified_as' => element.Classified_As__c,
                'extraction' => element.Extraction_Status__c,
                'rule_validation' => element.Rule_Validation_Status__c,
                'issue' => element.Element_Narrative__c,
                'rules_not_passed' => rulesByElement.get(element.Id) ?? new List<Object>()
            });
        }
        return new Map<String, Object>{
            'package' => run.Package__r.Name + ' (' + run.Package__r.Package_Name__c + ')',
            'package_type' => run.Package__r.Type__c,
            'overall_health' => (run.Package__r.Health__c ?? 'Red').toUpperCase(),
            'rule_pass_rate' => run.RuleValidationPassRate__c,
            'rules_passed' => passed,
            'rules_not_passed' => notPassed,
            'elements' => elementFacts,
            'package_rules_not_passed' => packageRules,
            'issue_summary' => run.Issue_Summary__c
        };
    }

    /**
     * Summary status of an element from its stage results: the worst stage wins; a required element without a file
     * is MISSING.
     */
    @TestVisible
    private static String elementStatus(DNAMS_Package_Element__c element, Boolean hasDocument) {
        if (element.Is_Required__c && !hasDocument) {
            return 'MISSING';
        }
        Set<String> statuses = new Set<String>{ element.Classification_Status__c, element.Extraction_Status__c, element.Rule_Validation_Status__c };
        if (statuses.contains('Failed')) {
            return 'FAILED';
        }
        if (statuses.contains('Needs Review') || statuses.contains('In Progress')) {
            return 'NEEDS_REVIEW';
        }
        return 'PASSED';
    }

    /**
     * Validates and normalises the model's JSON (code fences or text around it are ignored).
     * @throws DNAMSPipelineException when the answer has no JSON object or no headline
     */
    @TestVisible
    private static Map<String, Object> parseSummary(String raw) {
        Integer start = raw?.indexOf('{') ?? -1;
        Integer finish = raw?.lastIndexOf('}') ?? -1;
        if (start < 0 || finish <= start) {
            throw new DNAMSPipelineException('The narrative is not a JSON object.');
        }
        Map<String, Object> answer = (Map<String, Object>) JSON.deserializeUntyped(raw.substring(start, finish + 1));
        String headline = text(answer.get('headline'));
        if (String.isBlank(headline)) {
            throw new DNAMSPipelineException('The narrative has no headline.');
        }
        List<Object> elements = new List<Object>();
        for (Object item : asList(answer.get('elements'))) {
            if (!(item instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> element = (Map<String, Object>) item;
            String status = text(element.get('status')).toUpperCase().replace(' ', '_');
            elements.add(new Map<String, Object>{
                'element' => text(element.get('element')).left(120),
                'status' => ELEMENT_STATUSES.contains(status) ? status : 'NEEDS_REVIEW',
                'findings' => strings(element.get('findings'))
            });
        }
        return new Map<String, Object>{
            'headline' => headline.left(200),
            'summary' => text(answer.get('summary')).left(600),
            'elements' => elements,
            'next_steps' => strings(answer.get('next_steps'))
        };
    }

    /**
     * The same structure built from the facts without AI (model failure or bad answer).
     */
    @TestVisible
    private static Map<String, Object> fallbackSummary(Map<String, Object> facts) {
        List<Object> elements = new List<Object>();
        for (Object item : asList(facts.get('elements'))) {
            Map<String, Object> element = (Map<String, Object>) item;
            String status = text(element.get('status'));
            if (status == 'PASSED') {
                continue;
            }
            List<Object> findings = new List<Object>();
            if (String.isNotBlank(text(element.get('issue')))) {
                findings.add(text(element.get('issue')));
            }
            for (Object rule : asList(element.get('rules_not_passed'))) {
                findings.add(ruleFinding((Map<String, Object>) rule));
            }
            if (findings.isEmpty()) {
                findings.add(status == 'MISSING' ? 'The required document is missing.' : 'The automated review did not pass this element.');
            }
            elements.add(new Map<String, Object>{
                'element' => element.get('element'),
                'status' => status,
                'findings' => firstItems(findings)
            });
        }
        List<Object> packageFindings = new List<Object>();
        for (Object rule : asList(facts.get('package_rules_not_passed'))) {
            packageFindings.add(ruleFinding((Map<String, Object>) rule));
        }
        if (elements.isEmpty() && packageFindings.isEmpty() && String.isNotBlank(text(facts.get('issue_summary')))) {
            for (String line : text(facts.get('issue_summary')).split('\n')) {
                if (String.isNotBlank(line)) {
                    packageFindings.add(line.removeStart('- ').trim());
                }
            }
        }
        if (!packageFindings.isEmpty()) {
            elements.add(new Map<String, Object>{
                'element' => 'Package',
                'status' => 'NEEDS_REVIEW',
                'findings' => firstItems(packageFindings)
            });
        }
        Boolean clean = elements.isEmpty();
        return new Map<String, Object>{
            'headline' => clean ? 'All checks passed' : 'A few things need a closer look',
            'summary' => clean
                ? 'Every required document came in, was recognised and agrees with the dealer\'s records.'
                : (elements.size() == 1 ? 'One item' : elements.size() + ' items') + ' did not line up during the review. The details are below.',
            'elements' => elements,
            'next_steps' => clean
                ? new List<Object>{ 'Proceed with the package review.' }
                : new List<Object>{ 'Review the findings below.', 'Return the package to the dealer if documents must be replaced.' }
        };
    }

    /**
     * Plain-text version of the summary for emails and the Return to Dealer message.
     */
    @TestVisible
    private static String toPlainText(Map<String, Object> summary) {
        List<String> lines = new List<String>{ text(summary.get('headline')) + ' [' + text(summary.get('overall_health')) + ']' };
        if (String.isNotBlank(text(summary.get('summary')))) {
            lines.add(text(summary.get('summary')));
        }
        List<Object> elements = asList(summary.get('elements'));
        if (!elements.isEmpty()) {
            lines.add('');
            for (Object item : elements) {
                Map<String, Object> element = (Map<String, Object>) item;
                lines.add('- ' + text(element.get('element')) + ' (' + text(element.get('status')).replace('_', ' ') + ')');
                for (Object finding : asList(element.get('findings'))) {
                    lines.add('    * ' + text(finding));
                }
            }
        }
        List<Object> steps = asList(summary.get('next_steps'));
        if (!steps.isEmpty()) {
            lines.add('');
            lines.add('Next steps:');
            for (Object step : steps) {
                lines.add('- ' + text(step));
            }
        }
        return String.join(lines, '\n');
    }

    // Non-AI wording for a rule that did not pass, e.g. Legal Name Match - "ABC LLC" does not match "ABC, LLC".
    private static String ruleFinding(Map<String, Object> rule) {
        return text(rule.get('rule')) + ' - ' + text(rule.get('reason'));
    }

    private static List<Object> asList(Object value) {
        return value instanceof List<Object> ? (List<Object>) value : new List<Object>();
    }

    private static List<Object> strings(Object value) {
        List<Object> result = new List<Object>();
        for (Object item : asList(value)) {
            if (String.isNotBlank(text(item)) && result.size() < MAX_ITEMS) {
                result.add(text(item).left(400));
            }
        }
        return result;
    }

    private static List<Object> firstItems(List<Object> items) {
        List<Object> first = new List<Object>();
        for (Integer i = 0; i < items.size() && i < MAX_ITEMS; i++) {
            first.add(items[i]);
        }
        return first;
    }

    private static String text(Object value) {
        return value == null ? '' : String.valueOf(value).trim();
    }
}
