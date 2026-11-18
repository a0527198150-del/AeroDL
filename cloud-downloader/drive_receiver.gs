/**
 * Deploy as Web app: Execute as Me, access Anyone.
 * Script Properties: DRIVE_FOLDER_ID and DRIVE_UPLOAD_SECRET.
 */
function doPost(e) {
  try {
    const props = PropertiesService.getScriptProperties();
    const secret = props.getProperty('DRIVE_UPLOAD_SECRET');
    const folderId = props.getProperty('DRIVE_FOLDER_ID');
    if (!secret || !folderId || !e || !e.postData) throw new Error('Not configured');
    const input = JSON.parse(e.postData.contents);
    const name = String(input.name || '');
    const data = String(input.data || '');
    const given = String(input.signature || '').toLowerCase();
    if (!name || name.length > 180 || !name.toLowerCase().endsWith('.mp3') ||
        name.includes('/') || name.includes('\\')) throw new Error('Invalid filename');
    if (!data || data.length > 17 * 1024 * 1024 ||
        !/^[a-zA-Z0-9+/]*={0,2}$/.test(data)) throw new Error('Invalid content');
    const bytes = Utilities.computeHmacSha256Signature(name + '\n' + data, secret);
    const expected = bytes.map(function(n) {
      return ('0' + (n & 255).toString(16)).slice(-2);
    }).join('');
    if (given.length !== expected.length) throw new Error('Unauthorized');
    let diff = 0;
    for (let i = 0; i < expected.length; i++) {
      diff |= given.charCodeAt(i) ^ expected.charCodeAt(i);
    }
    if (diff !== 0) throw new Error('Unauthorized');
    const blob = Utilities.newBlob(Utilities.base64Decode(data), 'audio/mpeg', name);
    const file = DriveApp.getFolderById(folderId).createFile(blob);
    return reply({ok: true, id: file.getId()});
  } catch (err) {
    console.error(String(err));
    return reply({ok: false, error: 'Upload rejected'});
  }
}

function doGet() {
  return reply({ok: true, service: 'Drive receiver'});
}

function reply(data) {
  return ContentService.createTextOutput(JSON.stringify(data))
    .setMimeType(ContentService.MimeType.JSON);
}
