/**
 * @description     Contract for a MuleSoft IDP document extraction client. Implemented by DNAMSIDPCallout (live)
 *                  and DNAMSIDPStubCallout (stub mode and tests). Resolved through DNAMSIDPActionUtil.getClient().
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 **/
public interface IDocumentExtractionClient {
    /**
     * @description Submits one file to an IDP action (POST). Never throws; failures come back as isSuccess = false.
     * @param request Action, file name, file body and signed callback URL
     * @return        Outcome of the POST including the execution id
     **/
    DNAMSIDPWrapper.SubmitResult submitDocument(DNAMSIDPWrapper.SubmitRequest request);

    /**
     * @description Reads the result of one IDP execution (GET). Never throws; failures come back as isSuccess = false.
     * @param action      IDP action the execution belongs to
     * @param executionId MuleSoft execution id returned by submitDocument
     * @return            Execution status and raw response body
     **/
    DNAMSIDPWrapper.ExecutionResult fetchExecution(DNAMSIDPWrapper.ActionConfig action, String executionId);
}
