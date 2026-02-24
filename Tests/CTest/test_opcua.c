#include <open62541/client.h>
#include <open62541/client_config_default.h>
#include <open62541/client_highlevel.h>
#include <stdio.h>

int main(void) {
    printf("Testing open62541 connection...\n");
    
    // Create client
    UA_Client *client = UA_Client_new();
    UA_ClientConfig_setDefault(UA_Client_getConfig(client));
    
    // Connect
    UA_StatusCode status = UA_Client_connect(client, "opc.tcp://mac:4840");
    
    if (status == UA_STATUSCODE_GOOD) {
        printf("✅ Connected successfully!\n");
        
        // Read a simple node (Server Status)
        UA_Variant value;
        UA_Variant_init(&value);
        
        status = UA_Client_readValueAttribute(client, UA_NODEID_NUMERIC(0, UA_NS0ID_SERVER_SERVERSTATUS_STATE), &value);
        
        if (status == UA_STATUSCODE_GOOD) {
            printf("✅ Read value successfully!\n");
            if (UA_Variant_isScalar(&value)) {
                printf("Server state: %d\n", *(UA_Int32*)value.data);
            }
        } else {
            printf("❌ Read failed: 0x%08x\n", status);
        }
        
        UA_Variant_clear(&value);
        
        // Disconnect
        UA_Client_disconnect(client);
    } else {
        printf("❌ Connection failed: 0x%08x\n", status);
    }
    
    UA_Client_delete(client);
    printf("Test complete.\n");
    
    return 0;
}
