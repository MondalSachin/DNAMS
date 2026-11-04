/**
 * @description     Unit tests for DNAMSStructureValidationUtil.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 **/
@IsTest
private class DNAMSStructureValidationUtilTest {
    // Same shape as extraction_schemas/*.json, trimmed
    private static final String SCHEMA = '{"actionName":"Test","configuration":{"content":{"output":{'
        + '"fields":{"DealerCode":{"required":false},"Landlord":{"required":false}},'
        + '"tables":{"AddressTable":{"Status":{"required":false},"AddressType":{"required":false}}},'
        + '"tableExtras":{"AddressTable":{"description":"x"}}}}}}';

    /**
     * @description Matching value-only output passes; a null value counts as present.
     **/
    @IsTest
    static void testValidateMatchingOutputPasses() {
        DNAMSIDPWrapper.NormalizedOutput output = DNAMSIDPWrapper.normalizeOutput(
            '{"DealerCode":"40718","Landlord":null,"AddressTable":[{"Status":"Confirmed","AddressType":"Mailing"}]}'
        );
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            DNAMSStructureValidationUtil.ValidationResult result = DNAMSStructureValidationUtil.validate(SCHEMA, output);
            Test.stopTest();
            Assert.isTrue(result.isValid, 'Output matches the schema');
            Assert.isTrue(result.missingKeys.isEmpty(), 'No missing keys');
        }
    }

    /**
     * @description Missing field and column plus unexpected field and column are reported.
     **/
    @IsTest
    static void testValidateReportsMissingAndUnexpected() {
        DNAMSIDPWrapper.NormalizedOutput output = DNAMSIDPWrapper.normalizeOutput(
            '{"DealerCode":"40718","Extra":"x","AddressTable":[{"Status":"Confirmed","Bogus":"y"}]}'
        );
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            DNAMSStructureValidationUtil.ValidationResult result = DNAMSStructureValidationUtil.validate(SCHEMA, output);
            Test.stopTest();
            Assert.isFalse(result.isValid, 'Mismatch fails');
            Assert.areEqual(new List<String>{ 'AddressTable.AddressType', 'Landlord' }, result.missingKeys, 'Missing keys sorted');
            Assert.areEqual(new List<String>{ 'AddressTable.Bogus', 'Extra' }, result.unexpectedKeys, 'Unexpected keys sorted');
        }
    }

    /**
     * @description A table returned with zero rows does not report its columns as missing.
     **/
    @IsTest
    static void testValidateEmptyTablePasses() {
        DNAMSIDPWrapper.NormalizedOutput output = DNAMSIDPWrapper.normalizeOutput(
            '{"fields":{"DealerCode":{"value":"1"},"Landlord":null},"tables":{"AddressTable":[]}}'
        );
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            DNAMSStructureValidationUtil.ValidationResult result = DNAMSStructureValidationUtil.validate(SCHEMA, output);
            Test.stopTest();
            Assert.isTrue(result.isValid, 'Empty table is valid');
        }
    }

    /**
     * @description A schema without configuration.content.output throws DNAMSPipelineException.
     **/
    @IsTest
    static void testValidateInvalidSchemaThrows() {
        String message;
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            try {
                DNAMSStructureValidationUtil.validate('{"configuration":{}}', new DNAMSIDPWrapper.NormalizedOutput());
            } catch (DNAMSPipelineException e) {
                message = e.getMessage();
            }
            Test.stopTest();
        }
        Assert.isTrue(message.contains('configuration.content.output'), 'Schema error is explicit');
    }
}
