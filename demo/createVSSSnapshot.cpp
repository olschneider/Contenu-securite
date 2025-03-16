#include <windows.h>
#include <vss.h>
#include <vsbackup.h>
#include <iostream>
#include <vector>

#pragma comment(lib, "VssApi.lib")
#pragma comment(lib, "Ole32.lib")

// Define GUID_NULL
const GUID GUID_NULL = { 0, 0, 0, { 0, 0, 0, 0, 0, 0, 0, 0 } };

void CreateShadowCopy(const std::wstring& volume) {
    HRESULT hr;
    IVssBackupComponents* pVssObject = nullptr;
    VSS_ID SnapshotSetId = GUID_NULL;
    VSS_ID SnapshotId = GUID_NULL;
    IVssAsync* pAsync = nullptr;

    // Initialize COM library
    hr = CoInitialize(NULL);
    if (FAILED(hr)) {
        std::wcerr << L"Failed to initialize COM library. Error: " << hr << std::endl;
        return;
    }

    // Create VSS backup components object
    hr = CreateVssBackupComponents(&pVssObject);
    if (FAILED(hr)) {
        std::wcerr << L"Failed to create VSS backup components object. Error: " << hr << std::endl;
        CoUninitialize();
        return;
    }

    // Initialize for backup
    hr = pVssObject->InitializeForBackup();
    if (FAILED(hr)) {
        std::wcerr << L"Failed to initialize for backup. Error: " << hr << std::endl;
        pVssObject->Release();
        CoUninitialize();
        return;
    }

    // Set the context to backup
    hr = pVssObject->SetContext(VSS_CTX_BACKUP);
    if (FAILED(hr)) {
        std::wcerr << L"Failed to set context to backup. Error: " << hr << std::endl;
        pVssObject->Release();
        CoUninitialize();
        return;
    }

    // Start snapshot set
    hr = pVssObject->StartSnapshotSet(&SnapshotSetId);
    if (FAILED(hr)) {
        std::wcerr << L"Failed to start snapshot set. Error: " << hr << std::endl;
        pVssObject->Release();
        CoUninitialize();
        return;
    }

    // Convert const wchar_t* to wchar_t*
    std::vector<wchar_t> volumePath(volume.begin(), volume.end());
    volumePath.push_back(L'\0'); // Null-terminate the string

    // Add volume to snapshot set
    hr = pVssObject->AddToSnapshotSet(volumePath.data(), GUID_NULL, &SnapshotId);
    if (FAILED(hr)) {
        std::wcerr << L"Failed to add volume to snapshot set. Error: " << hr << std::endl;
        pVssObject->Release();
        CoUninitialize();
        return;
    }

    // Do the snapshot
    hr = pVssObject->DoSnapshotSet(&pAsync);
    if (FAILED(hr)) {
        std::wcerr << L"Failed to do snapshot set. Error: " << hr << std::endl;
        pVssObject->Release();
        CoUninitialize();
        return;
    }

    // Wait for the async operation to complete
    hr = pAsync->Wait();
    pAsync->Release();
    if (FAILED(hr)) {
        std::wcerr << L"Failed to wait for snapshot set completion. Error: " << hr << std::endl;
        pVssObject->Release();
        CoUninitialize();
        return;
    }

    // Get the snapshot properties
    VSS_SNAPSHOT_PROP prop;
    hr = pVssObject->GetSnapshotProperties(SnapshotId, &prop);
    if (SUCCEEDED(hr)) {
        std::wcout << L"Shadow copy created successfully at: " << prop.m_pwszSnapshotDeviceObject << std::endl;
    } else {
        std::wcerr << L"Failed to get snapshot properties. Error: " << hr << std::endl;
    }

    // Clean up
    pVssObject->Release();
    CoUninitialize();
}

int main() {
    std::wstring volume = L"C:\\";
    CreateShadowCopy(volume);
    return 0;
}
