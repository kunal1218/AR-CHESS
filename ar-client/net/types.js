/**
 * @typedef {{x:number,y:number,z:number}} Vector3
 * @typedef {{x:number,y:number,z:number,w:number}} Quaternion
 * @typedef {{pos:Vector3,rot:Quaternion}} Pose
 *
 * @typedef {{marker_id:string}} ScanRoomRequest
 * @typedef {{room_id:string}} ScanRoomResponse
 *
 * @typedef {{id:string,cloud_anchor_id:string,pose:Pose,active:boolean}} AnchorRecord
 * @typedef {{anchors:AnchorRecord[]}} AnchorsResponse
 *
 * @typedef {{board_id:string,fen:string,version:number}} BoardState
 *
 * @typedef {{fen:string,version:number,legal:boolean,reason?:string}} PostMoveResponse
 *
 * @typedef {{
 *  scanRoom:(markerId:string)=>Promise<ScanRoomResponse>,
 *  getAnchors:(roomId:string)=>Promise<AnchorsResponse>,
 *  getBoard:(boardId:string)=>Promise<BoardState>,
 *  postMove:(boardId:string,uci:string,expectedVersion:number)=>Promise<PostMoveResponse>,
 * }} ArClientApi
 */

export {};
