// Fills AIReviewStageResult__c.RuleType__c on Rule Validation rows created before the field existed (2026-11-05).
// Type comes from DNAMSRule__mdt by RuleId__c; the PIR row is a Validation. Re-runnable (only blank rows).
Map<String, String> typeByRule = new Map<String, String>{ 'PIR' => 'Validation' };
for (DNAMSRule__mdt rule : [SELECT DeveloperName, RuleType__c FROM DNAMSRule__mdt]) {
    typeByRule.put(rule.DeveloperName, rule.RuleType__c);
}
List<AIReviewStageResult__c> rows = [
    SELECT Id, RuleId__c FROM AIReviewStageResult__c
    WHERE Stage__c = 'Rule Validation' AND RuleType__c = null AND RuleId__c != null LIMIT 9000
];
List<AIReviewStageResult__c> updates = new List<AIReviewStageResult__c>();
for (AIReviewStageResult__c row : rows) {
    String ruleType = typeByRule.get(row.RuleId__c);
    if (ruleType != null) {
        updates.add(new AIReviewStageResult__c(Id = row.Id, RuleType__c = ruleType));
    }
}
update updates;
System.debug('BACKFILLED ' + updates.size() + ' of ' + rows.size());
