/**
 * @description     Rule validation steps 4-7 for one package: resolves each rule's source and reference values
 *                  (step 4) from the consolidated extraction JSON (step 5), the package's records (step 6) or static
 *                  values, then decides ExactMatch rules in Apex (step 7). AIMatch rules come back Pending with their
 *                  resolved values for DNAMSAIRuleValidationQueueable.
 *                  Keys: extraction.<IDP action>.<field>; Package.<field> or Package.<lookup>__r[.<relationship>].<field>
 *                  (up to three levels); Static literals, a JSON list for IN / NOT IN, date tokens {TODAY} / {TODAY-n}.
 *                  Not Applicable: the source or reference document was not uploaded, or a record path is empty.
 *                  ExactMatch normalisation: dates, then numbers, then booleans (true/yes, false/no), then text
 *                  (trimmed, single-spaced, case-insensitive; punctuation kept).
 * @author          Sachin Mondal
 * @group           DNAMS AI Review
 * @last modified on 2026-11-04
 * @last modified by Sachin Mondal
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-04   Sachin Mondal   Initial version
 **/
// Exception to guideline: without sharing because the system pipeline must read the package's related records regardless of ownership
@SuppressWarnings('PMD.CyclomaticComplexity,PMD.CognitiveComplexity')
public without sharing class DNAMSRuleEvaluator {
    private static final String EXTRACTION_PREFIX = 'extraction.';
    private static final String PACKAGE_PREFIX = 'package.';
    private static final Pattern RECORD_PATH = Pattern.compile('^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*){0,2}$');
    private static final Pattern TODAY_TOKEN = Pattern.compile('^\\{TODAY\\s*(([+-])\\s*(\\d+))?\\}$');
    private static final Pattern ISO_DATE = Pattern.compile('^(\\d{4})-(\\d{1,2})-(\\d{1,2})([T ].*)?$');
    private static final Pattern US_DATE = Pattern.compile('^(\\d{1,2})[-/](\\d{1,2})[-/](\\d{4})$');
    private static final Pattern NUMBER_VALUE = Pattern.compile('^-?[0-9][0-9,]*(\\.[0-9]+)?%?$|^-?\\.[0-9]+%?$');
    private static final Set<String> TRUE_WORDS = new Set<String>{ 'true', 'yes' };
    private static final Set<String> FALSE_WORDS = new Set<String>{ 'false', 'no' };

    private final Id packageId;
    private final Map<String, List<Map<String, Object>>> documentsByAction = new Map<String, List<Map<String, Object>>>();
    private final Map<String, Object> recordValueByPath = new Map<String, Object>();
    private final Map<String, String> recordErrorByPath = new Map<String, String>();

    /**
     * @description Two values that cannot be compared (not both dates or numbers, or an unknown comparator).
     **/
    public class NotComparableException extends Exception {
    }

    /**
     * @description Outcome of one rule. AIMatch rules are Pending (verdict null) unless Not Applicable.
     **/
    public class Outcome {
        public String verdict;
        public String reasoning;
        public String sourceValue;
        public String referenceValue;
        public Boolean isPending = false;
    }

    /**
     * @description Values of one side of a rule.
     **/
    private class Side {
        Map<String, List<Object>> valuesByKey = new Map<String, List<Object>>();
        List<String> missing = new List<String>(); // why the side is not applicable
        List<String> blankKeys = new List<String>();
        String error;

        Boolean isMissing() {
            return !missing.isEmpty();
        }

        List<Object> flat() {
            List<Object> values = new List<Object>();
            for (List<Object> keyValues : valuesByKey.values()) {
                for (Object value : keyValues) {
                    values.addAll(expand(value));
                }
            }
            return values;
        }

        String display() {
            if (valuesByKey.isEmpty()) {
                return null;
            }
            if (valuesByKey.size() == 1) {
                List<Object> only = valuesByKey.values()[0];
                return only.size() == 1 ? text(only[0]) : JSON.serialize(only);
            }
            Map<String, Object> byShortKey = new Map<String, Object>();
            for (String key : valuesByKey.keySet()) {
                List<Object> values = valuesByKey.get(key);
                byShortKey.put(key.substringAfterLast('.'), values.size() == 1 ? values[0] : values);
            }
            return JSON.serialize(byShortKey);
        }
    }

    /**
     * @description Creates the evaluator for one package and its consolidated extraction JSON.
     * @param packageId          DNAMS_Package__c id (root of Package.* record keys)
     * @param consolidatedJson   AI_Package_Review_Run__c.ConsolidatedExtractionJSON__c
     **/
    public DNAMSRuleEvaluator(Id packageId, String consolidatedJson) {
        this.packageId = packageId;
        if (String.isBlank(consolidatedJson)) {
            return;
        }
        Map<String, Object> byAction = (Map<String, Object>) JSON.deserializeUntyped(consolidatedJson);
        for (String action : byAction.keySet()) {
            List<Map<String, Object>> documents = new List<Map<String, Object>>();
            for (Object entry : (List<Object>) byAction.get(action)) {
                Object data = ((Map<String, Object>) entry).get('data');
                if (data instanceof Map<String, Object>) {
                    documents.add((Map<String, Object>) data);
                }
            }
            documentsByAction.put(action.toLowerCase(), documents);
        }
    }

    /**
     * @description Evaluates one rule (steps 4-7).
     * @param rule The rule
     * @return     The outcome
     **/
    public Outcome evaluate(DNAMSRule__mdt rule) {
        Outcome result = new Outcome();
        Side source = resolve(rule.SourceFieldType__c, rule.SourceFieldKey__c);
        Side reference = resolve(rule.ReferenceFieldType__c, rule.ReferenceFieldKey__c);
        result.sourceValue = source.display();
        result.referenceValue = reference.display();

        if (rule.RuleType__c == DNAMSPipelineConstants.RULE_TYPE_COMPLETENESS) {
            return completeness(result, source);
        }
        if (source.error != null || reference.error != null) {
            return decided(result, DNAMSPipelineConstants.VERDICT_CANNOT_DECIDE, source.error ?? reference.error);
        }
        if (source.isMissing() || reference.isMissing()) {
            List<String> reasons = new List<String>(source.missing);
            reasons.addAll(reference.missing);
            return decided(result, DNAMSPipelineConstants.VERDICT_NOT_APPLICABLE, String.join(reasons, '; '));
        }
        if (rule.ValidationMethod__c == DNAMSPipelineConstants.METHOD_AI) {
            result.isPending = true;
            return result;
        }
        if (!source.blankKeys.isEmpty()) {
            return decided(result, DNAMSPipelineConstants.VERDICT_FAIL, 'The document does not show a value for ' + labels(source.blankKeys) + '.');
        }
        return exactMatch(result, rule.Comparator__c, source.flat(), reference.flat());
    }

    /**
     * @description Completeness: every listed field of the documents that were uploaded must have a value.
     * @param result The outcome being built
     * @param source The listed fields
     * @return       PASS, FAIL naming the blank fields, or NOT_APPLICABLE when none of the documents was uploaded
     **/
    private static Outcome completeness(Outcome result, Side source) {
        if (source.valuesByKey.isEmpty()) {
            return decided(result, DNAMSPipelineConstants.VERDICT_NOT_APPLICABLE, String.join(source.missing, '; '));
        }
        if (!source.blankKeys.isEmpty()) {
            return decided(result, DNAMSPipelineConstants.VERDICT_FAIL, 'These required fields are blank on the document: ' + labels(source.blankKeys) + '.');
        }
        return decided(result, DNAMSPipelineConstants.VERDICT_PASS, 'All ' + source.valuesByKey.size() + ' required fields are filled in.');
    }

    /**
     * @description Step 7: deterministic comparison. Every source value must satisfy the comparator.
     * @param result     The outcome being built
     * @param comparator EQUALS, NOT EQUALS, IN, NOT IN, GE, GT, LE or LT
     * @param sources    Source values
     * @param references Reference values
     * @return           PASS, FAIL or CANNOT_DECIDE
     **/
    private static Outcome exactMatch(Outcome result, String comparator, List<Object> sources, List<Object> references) {
        if (sources.isEmpty() || references.isEmpty()) {
            return decided(result, DNAMSPipelineConstants.VERDICT_CANNOT_DECIDE, 'There is no value to compare.');
        }
        try {
            for (Object sourceValue : sources) {
                if (!satisfies(comparator, sourceValue, references)) {
                    return decided(result, DNAMSPipelineConstants.VERDICT_FAIL, sentence(comparator, sourceValue, references, false));
                }
            }
        } catch (NotComparableException notComparable) {
            return decided(result, DNAMSPipelineConstants.VERDICT_CANNOT_DECIDE, notComparable.getMessage());
        }
        return decided(result, DNAMSPipelineConstants.VERDICT_PASS, sentence(comparator, sources.size() == 1 ? sources[0] : null, references, true));
    }

    /**
     * @description Plain-English result of a comparison, e.g. "ABC Motors LLC" does not match "ABC Motors, LLC".
     * @param comparator The comparator
     * @param value      The source value (null: several values, all satisfied)
     * @param references The reference values
     * @param passed     Whether the comparison passed
     * @return           The sentence
     **/
    @TestVisible
    private static String sentence(String comparator, Object value, List<Object> references, Boolean passed) {
        String subject = value == null ? 'Every value' : quote(value);
        String reference = describe(references);
        Boolean isDate = value != null && toDate(value) != null && toDate(references[0]) != null;
        switch on (comparator ?? 'EQUALS') {
            when 'NOT EQUALS' {
                return passed ? subject + ' is different from ' + reference + ', as expected.' : subject + ' should be different from ' + reference + ', but it is the same.';
            }
            when 'IN' {
                return passed ? subject + ' is one of the accepted values (' + reference + ').' : subject + ' is not one of the accepted values (' + reference + ').';
            }
            when 'NOT IN' {
                return passed ? subject + ' is not one of the values that are not allowed (' + reference + ').' : subject + ' is one of the values that are not allowed (' + reference + ').';
            }
            when 'GE' {
                return isDate
                    ? (passed ? subject + ' is on or after ' + reference + '.' : subject + ' is before ' + reference + ', which is too early.')
                    : (passed ? subject + ' is at least ' + reference + '.' : subject + ' is below the minimum of ' + reference + '.');
            }
            when 'GT' {
                return isDate
                    ? (passed ? subject + ' is after ' + reference + '.' : subject + ' is not after ' + reference + '.')
                    : (passed ? subject + ' is more than ' + reference + '.' : subject + ' is not more than ' + reference + '.');
            }
            when 'LE' {
                return isDate
                    ? (passed ? subject + ' is on or before ' + reference + '.' : subject + ' is after ' + reference + ', which is too late.')
                    : (passed ? subject + ' is at most ' + reference + '.' : subject + ' is above the maximum of ' + reference + '.');
            }
            when 'LT' {
                return isDate
                    ? (passed ? subject + ' is before ' + reference + '.' : subject + ' is not before ' + reference + '.')
                    : (passed ? subject + ' is less than ' + reference + '.' : subject + ' is not less than ' + reference + '.');
            }
            when else {
                return passed ? subject + ' matches ' + reference + '.' : subject + ' does not match ' + reference + '.';
            }
        }
    }

    /**
     * @description One source value against the reference values.
     * @param comparator The comparator
     * @param value      One source value
     * @param references All reference values
     * @return           Whether the value satisfies the comparator
     **/
    @TestVisible
    private static Boolean satisfies(String comparator, Object value, List<Object> references) {
        switch on (comparator ?? 'EQUALS') {
            when 'EQUALS', 'IN' {
                return matchesAny(value, references);
            }
            when 'NOT EQUALS', 'NOT IN' {
                return !matchesAny(value, references);
            }
            when 'GE' {
                return compare(value, references[0]) >= 0;
            }
            when 'GT' {
                return compare(value, references[0]) > 0;
            }
            when 'LE' {
                return compare(value, references[0]) <= 0;
            }
            when 'LT' {
                return compare(value, references[0]) < 0;
            }
            when else {
                throw new NotComparableException('Unknown comparator ' + comparator + '.');
            }
        }
    }

    private static Boolean matchesAny(Object value, List<Object> references) {
        for (Object reference : references) {
            if (areEqual(value, reference)) {
                return true;
            }
        }
        return false;
    }

    /**
     * @description Normalised equality: dates, then numbers, then booleans, then text.
     * @param left  One value
     * @param right The other value
     * @return      Whether they are equal
     **/
    @TestVisible
    private static Boolean areEqual(Object left, Object right) {
        Date leftDate = toDate(left);
        Date rightDate = toDate(right);
        if (leftDate != null && rightDate != null) {
            return leftDate == rightDate;
        }
        Decimal leftNumber = toNumber(left);
        Decimal rightNumber = toNumber(right);
        if (leftNumber != null && rightNumber != null) {
            return leftNumber == rightNumber;
        }
        Boolean leftBoolean = toBoolean(left);
        Boolean rightBoolean = toBoolean(right);
        if (leftBoolean != null && rightBoolean != null) {
            return leftBoolean == rightBoolean;
        }
        return normalise(left).equals(normalise(right));
    }

    /**
     * @description Orders two dates or two numbers.
     * @param left  One value
     * @param right The other value
     * @return      Negative, zero or positive
     * @throws NotComparableException when the values are not both dates or both numbers
     **/
    @TestVisible
    private static Integer compare(Object left, Object right) {
        Date leftDate = toDate(left);
        Date rightDate = toDate(right);
        if (leftDate != null && rightDate != null) {
            return leftDate < rightDate ? -1 : (leftDate > rightDate ? 1 : 0);
        }
        Decimal leftNumber = toNumber(left);
        Decimal rightNumber = toNumber(right);
        if (leftNumber != null && rightNumber != null) {
            return leftNumber < rightNumber ? -1 : (leftNumber > rightNumber ? 1 : 0);
        }
        throw new NotComparableException('"' + text(left) + '" and "' + text(right) + '" cannot be compared as dates or numbers.');
    }

    @TestVisible
    private static Date toDate(Object value) {
        if (value instanceof Date) {
            return (Date) value;
        }
        String raw = text(value).trim();
        Matcher token = TODAY_TOKEN.matcher(raw.toUpperCase());
        if (token.matches()) {
            Integer days = token.group(3) == null ? 0 : Integer.valueOf(token.group(3));
            return Date.today().addDays(token.group(2) == '-' ? -days : days);
        }
        try {
            Matcher iso = ISO_DATE.matcher(raw);
            if (iso.matches()) {
                return validDate(Integer.valueOf(iso.group(1)), Integer.valueOf(iso.group(2)), Integer.valueOf(iso.group(3)));
            }
            Matcher us = US_DATE.matcher(raw);
            if (us.matches()) {
                return validDate(Integer.valueOf(us.group(3)), Integer.valueOf(us.group(1)), Integer.valueOf(us.group(2)));
            }
        } catch (Exception invalidDate) {
            return null;
        }
        return null;
    }

    // Date.newInstance rolls invalid parts over (month 13 -> next year), so out-of-range parts are rejected first.
    private static Date validDate(Integer year, Integer month, Integer day) {
        if (month < 1 || month > 12 || day < 1 || day > Date.daysInMonth(year, month)) {
            return null;
        }
        return Date.newInstance(year, month, day);
    }

    private static Decimal toNumber(Object value) {
        if (value instanceof Decimal) {
            return (Decimal) value;
        }
        String raw = text(value).trim();
        if (!NUMBER_VALUE.matcher(raw).matches()) {
            return null;
        }
        return Decimal.valueOf(raw.remove(',').remove('%'));
    }

    private static Boolean toBoolean(Object value) {
        if (value instanceof Boolean) {
            return (Boolean) value;
        }
        String raw = text(value).trim().toLowerCase();
        return TRUE_WORDS.contains(raw) ? true : (FALSE_WORDS.contains(raw) ? false : null);
    }

    private static String normalise(Object value) {
        return text(value).normalizeSpace().toLowerCase();
    }

    /**
     * @description Resolves one side of a rule.
     * @param fieldType Extraction, Record or Static
     * @param rawKey    The field key (a JSON list for several keys)
     * @return          The side's values
     **/
    private Side resolve(String fieldType, String rawKey) {
        Side side = new Side();
        List<String> keys = DNAMSRuleUtil.parseKeys(rawKey);
        if (fieldType == DNAMSPipelineConstants.FIELD_TYPE_STATIC) {
            List<Object> literals = new List<Object>();
            literals.addAll((List<Object>) keys);
            side.valuesByKey.put('static', literals);
            return side;
        }
        for (String key : keys) {
            if (fieldType == DNAMSPipelineConstants.FIELD_TYPE_RECORD) {
                resolveRecord(side, key);
            } else {
                resolveExtraction(side, key);
            }
        }
        return side;
    }

    /**
     * @description Step 5: extraction.<action>.<field> across every document of that IDP action.
     **/
    private void resolveExtraction(Side side, String key) {
        if (!key.toLowerCase().startsWith(EXTRACTION_PREFIX) || key.countMatches('.') < 2) {
            side.error = 'Invalid extraction key "' + key + '".';
            return;
        }
        String action = key.substringAfter('.').substringBefore('.');
        String field = key.substringAfter('.').substringAfter('.');
        List<Map<String, Object>> documents = documentsByAction.get(action.toLowerCase());
        if (documents == null || documents.isEmpty()) {
            side.missing.add('No ' + action + ' document was extracted');
            return;
        }
        List<Object> values = new List<Object>();
        Boolean anyBlank = false;
        for (Map<String, Object> data : documents) {
            Object value = data.get(field);
            anyBlank = anyBlank || isBlank(value);
            values.add(value);
        }
        if (anyBlank) {
            side.blankKeys.add(key);
        }
        side.valuesByKey.put(key, values);
    }

    /**
     * @description Step 6: Package.<path> on the package record, up to three levels below the package.
     **/
    private void resolveRecord(Side side, String key) {
        if (!key.toLowerCase().startsWith(PACKAGE_PREFIX)) {
            side.error = 'Record keys must start with "Package.": "' + key + '".';
            return;
        }
        String path = key.substringAfter('.');
        if (!recordValueByPath.containsKey(path) && !recordErrorByPath.containsKey(path)) {
            loadRecordValue(path);
        }
        if (recordErrorByPath.containsKey(path)) {
            side.error = recordErrorByPath.get(path);
            return;
        }
        Object value = recordValueByPath.get(path);
        if (isBlank(value)) {
            side.missing.add(key + ' has no value');
            return;
        }
        side.valuesByKey.put(key, new List<Object>{ value });
    }

    private void loadRecordValue(String path) {
        if (!RECORD_PATH.matcher(path).matches()) {
            recordErrorByPath.put(path, 'Invalid record path "Package.' + path + '" (at most three levels).');
            return;
        }
        try {
            List<SObject> rows = Database.queryWithBinds(
                'SELECT Id, ' + path + ' FROM DNAMS_Package__c WHERE Id = :packageId',
                new Map<String, Object>{ 'packageId' => packageId },
                AccessLevel.SYSTEM_MODE
            );
            SObject current = rows.isEmpty() ? null : rows[0];
            List<String> parts = path.split('\\.');
            for (Integer i = 0; i < parts.size() - 1 && current != null; i++) {
                current = current.getSObject(parts[i]);
            }
            recordValueByPath.put(path, current == null ? null : formatRecordValue(current.get(parts[parts.size() - 1])));
        } catch (Exception badPath) {
            recordErrorByPath.put(path, 'Record path "Package.' + path + '" could not be read: ' + badPath.getMessage());
        }
    }

    private static Object formatRecordValue(Object value) {
        if (value instanceof Address) {
            Address address = (Address) value;
            List<String> parts = new List<String>();
            for (String part : new List<String>{ address.getStreet(), address.getCity(),
                    String.join(new List<String>{ address.getStateCode() ?? address.getState() ?? '', address.getPostalCode() ?? '' }, ' ').trim(),
                    address.getCountry() }) {
                if (String.isNotBlank(part)) {
                    parts.add(part.normalizeSpace());
                }
            }
            return parts.isEmpty() ? null : String.join(parts, ', ');
        }
        return value;
    }

    /**
     * @description A value that is a JSON list (e.g. AreasPhotographed) or a list becomes its items.
     **/
    private static List<Object> expand(Object value) {
        if (value instanceof List<Object>) {
            return (List<Object>) value;
        }
        String raw = text(value).trim();
        if (raw.startsWith('[') && raw.endsWith(']')) {
            try {
                return (List<Object>) JSON.deserializeUntyped(raw);
            } catch (Exception notAList) {
                return new List<Object>{ value };
            }
        }
        return new List<Object>{ value };
    }

    private static Boolean isBlank(Object value) {
        if (value == null) {
            return true;
        }
        if (value instanceof List<Object>) {
            return ((List<Object>) value).isEmpty();
        }
        String raw = text(value).trim();
        return raw == '' || raw == '[]' || raw.equalsIgnoreCase('null');
    }

    private static String text(Object value) {
        if (value == null) {
            return '';
        }
        return value instanceof String ? (String) value : (value instanceof List<Object> || value instanceof Map<String, Object> ? JSON.serialize(value) : String.valueOf(value));
    }

    private static String describe(List<Object> values) {
        List<String> texts = new List<String>();
        for (Object value : values) {
            texts.add(quote(value));
        }
        if (texts.size() <= 1) {
            return texts.isEmpty() ? '' : texts[0];
        }
        String last = texts.remove(texts.size() - 1);
        return String.join(texts, ', ') + ' or ' + last;
    }

    private static String labels(List<String> keys) {
        List<String> names = new List<String>();
        for (String key : keys) {
            names.add(fieldLabel(key));
        }
        return String.join(names, ', ');
    }

    // Quoted value; date tokens such as {TODAY-90} are shown as the date they stand for.
    private static String quote(Object value) {
        String raw = text(value).trim();
        if (TODAY_TOKEN.matcher(raw.toUpperCase()).matches()) {
            Date day = toDate(raw);
            return Datetime.newInstance(day, Time.newInstance(0, 0, 0, 0)).format('MMM d, yyyy');
        }
        return '"' + raw + '"';
    }

    // extraction.DealerApplication.LegalNameOrDealerEntity -> "Legal Name Or Dealer Entity"
    @TestVisible
    private static String fieldLabel(String key) {
        return key.substringAfterLast('.').replaceAll('([a-z0-9])([A-Z])', '$1 $2').replaceAll('^is ', '').trim();
    }

    private static Outcome decided(Outcome result, String verdict, String reasoning) {
        result.verdict = verdict;
        result.reasoning = reasoning;
        return result;
    }
}
