/**
 * @description     HttpCalloutMock for the MuleSoft IDP API. Routes by HTTP method (POST = submit, GET = fetch),
 *                  counts calls and keeps the last request for assertions. A null status simulates a
 *                  CalloutException for that method.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 **/
public inherited sharing class DNAMSIDPCalloutMock implements HttpCalloutMock {
    public static Integer postCount = 0;
    public static Integer getCount = 0;
    public static HttpRequest lastRequest;

    private Integer postStatus;
    private String postBody;
    private Integer getStatus;
    private String getBody;

    /**
     * @description Creates the mock.
     * @param postStatus HTTP status for POST (null throws CalloutException)
     * @param postBody   Body for POST
     * @param getStatus  HTTP status for GET (null throws CalloutException)
     * @param getBody    Body for GET
     **/
    @SuppressWarnings('PMD.ExcessiveParameterList') // four-argument constructor is fixed by the build contract
    public DNAMSIDPCalloutMock(Integer postStatus, String postBody, Integer getStatus, String getBody) {
        this.postStatus = postStatus;
        this.postBody = postBody;
        this.getStatus = getStatus;
        this.getBody = getBody;
    }

    /**
     * @description Returns the configured response for the request's method.
     * @param request Outgoing request
     * @return        Mock response
     **/
    public HttpResponse respond(HttpRequest request) {
        lastRequest = request;
        Boolean isPost = request.getMethod() == 'POST';
        if (isPost) {
            postCount++;
        } else {
            getCount++;
        }
        Integer status = isPost ? postStatus : getStatus;
        if (status == null) {
            throw new CalloutException('Simulated IDP callout failure');
        }
        HttpResponse response = new HttpResponse();
        response.setHeader('Content-Type', 'application/json');
        response.setStatusCode(status);
        response.setBody((isPost ? postBody : getBody) ?? '');
        return response;
    }
}
