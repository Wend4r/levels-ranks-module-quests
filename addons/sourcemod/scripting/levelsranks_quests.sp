#pragma semicolon 1

#include <sourcemod>
#include <lvl_ranks>

#pragma newdecls required

#define SPPP_COMPILER 0

#if !SPPP_COMPILER
	#define decl static
#endif

#define SQL_CREATE_TABLE \
"CREATE TABLE IF NOT EXISTS `%s_quests` \
(\
	`accountid` int unsigned NOT NULL, \
	`quest` varchar(128) NOT NULL, \
	`progress` int unsigned NOT NULL DEFAULT 0, \
	PRIMARY KEY (`accountid`, `quest`)\
);"

#define SQL_LOAD_DATA \
"SELECT \
	`quest`, \
	`progress` \
FROM \
	`%s_quests` \
WHERE \
	`accountid` = %u;"

#define SQL_INSERT_DATA \
"INSERT INTO `%s_quests` \
(\
	`accountid`, \
	`quest`\
) \
VALUES "

#define SQL_UPDATE_DATA \
"UPDATE `%s_quests` SET\
	`progress` = %u \
WHERE \
	`accountid` = %u AND `quest` = '%s';"

#define SQL_DELETE_ALL_DATA \
"DELETE \
FROM \
	`%s_quests`"

enum struct QuestAwardedData
{
	int       iGiveExp;
	int       iMaxProgress;
	int       iNameIndex;
	int       iEventIndex;
	int       iEventBelongIndex;
	ArrayList hCondition;
}

enum struct PlayerData
{
	int       iQuestIndex;
	int       iProgress;
}

int       g_iAccountID[MAXPLAYERS + 1],
          g_iAdminFlags,
          g_iQuestsCount = 3;

char      g_sTableName[32],
          g_sTitleMenu[32];

ArrayList g_hQuests,
          g_hQuestsName,
          g_hEventsList,
          g_hEventsBelongs,
          g_hConditionParams,
          g_hConditionValues,
          g_hPlayerQuests[MAXPLAYERS + 1];

Database  g_hDatabase;

Handle    g_hQuestTimer;

public Plugin myinfo =
{
	name = "[Levels Ranks] Module - Quests",
	author = "Wend4r",
	version = PLUGIN_VERSION,
	url = "Discord: Wend4r#0001 | VK: vk.com/wend4r"
};

public void OnPluginStart()
{
	if(LR_IsLoaded())
	{
		LR_OnCoreIsReady();
	}

	LoadTranslations("lr_module_quests.phrases");
}

public void LR_OnCoreIsReady()
{
	LoadSettings();

	LR_Hook(LR_OnPlayerLoaded, LoadDataPlayer);
	LR_MenuHook(LR_SettingMenu, OnMenuCreated, OnMenuItemSelected);

	decl char sQuery[256];

	LR_GetTableName(g_sTableName, sizeof(g_sTableName));
	LR_GetTitleMenu(g_sTitleMenu, sizeof(g_sTitleMenu));

	FormatEx(sQuery, sizeof(sQuery), SQL_CREATE_TABLE, g_sTableName);
	(g_hDatabase = LR_GetDatabase()).Query(SQL_Callback, sQuery);

	RegConsoleCmd("sm_event", OnEnterCommand);
	RegConsoleCmd("sm_quest", OnEnterCommand);
	RegConsoleCmd("sm_quests", OnEnterCommand);
	RegServerCmd("sm_quests_reload", sm_quests_reload);
	RegServerCmd("sm_refresh_quests_data", sm_refresh_quests_data);
}

Action sm_quests_reload(int iClient)
{
	LoadSettings();

	return Plugin_Handled;
}

Action sm_refresh_quests_data(int iClient)
{
	OnQuestsUpdate(g_hQuestTimer);

	if(g_hQuestTimer)
	{
		// delete g_hQuestTimer;
		KillTimer(g_hQuestTimer);
		g_hQuestTimer = null;
	}
}

void LoadSettings()
{
	static char sPath[PLATFORM_MAX_PATH];

	if(sPath[0])
	{
		int i = 0, iLen = g_hQuests.Length;

		while(i != iLen)
		{
			view_as<ArrayList>(g_hQuests.Get(i++, QuestAwardedData::hCondition)).Close();
		}

		g_hQuests.Clear();
		g_hQuestsName.Clear();

		decl char sEventName[32];

		for(i = 0, iLen = g_hEventsList.Length; i != iLen; i++)
		{
			g_hEventsList.GetString(i, sEventName, sizeof(sEventName));
			UnhookEvent(sEventName, OnEventHandler);
		}

		g_hEventsList.Clear();
		g_hEventsBelongs.Clear();
		g_hConditionParams.Clear();
		g_hConditionValues.Clear();
	}
	else
	{
		BuildPath(Path_SM, sPath, sizeof(sPath), "configs/levels_ranks/quests.kv");

		g_hQuests = new ArrayList(sizeof(QuestAwardedData));
		g_hQuestsName = new ArrayList(32);		// char[128]
		g_hEventsList = new ArrayList(8);		// char[32]
		g_hEventsBelongs = new ArrayList(8);		// char[32]
		g_hConditionParams = new ArrayList(8);		// char[32]
		g_hConditionValues = new ArrayList(8);		// char[32]
	}

	SMCParser hParser = new SMCParser();

	hParser.OnEnterSection = OnNewSectionSettings;
	hParser.OnLeaveSection = OnEndSectionSettings;

	SMCError iError = hParser.ParseFile(sPath);

	if(iError != SMCError_Okay)
	{
		decl char sError[64];

		SMC_GetErrorString(iError, sError, sizeof(sError));
		SetFailState("%s - %s", sPath, sError);
	}

	if(g_hQuestTimer)
	{
		// delete g_hQuestTimer;
		KillTimer(g_hQuestTimer);
		g_hQuestTimer = null;
	}

	CreateTimer(float(86400 - (GetTime() % 86400)), OnQuestsUpdate);

	hParser.Close();
}

Action OnQuestsUpdate(Handle hPlugin)
{
	decl char sBuffer[128];

	FormatEx(sBuffer, sizeof(sBuffer), SQL_DELETE_ALL_DATA, g_sTableName);
	g_hDatabase.Query(SQL_Callback, sBuffer, 2);

	g_hQuestTimer = CreateTimer(86400.0, OnQuestsUpdate);

	LoadSettings();

	return Plugin_Handled;
}

static int g_iSection = 0;

static QuestAwardedData g_QuestAwardedData;

SMCResult OnSelectSettings(SMCParser hParser, const char[] sKey, const char[] sValue, bool bKeyQuotes, bool bValueQuotes)
{
	if(!strcmp(sKey, "admin_flags"))
	{
		g_iAdminFlags = ReadFlagString(sValue);
	}
	else if(!strcmp(sKey, "gived_quests"))
	{
		g_iQuestsCount = StringToInt(sValue);
	}
}

SMCResult OnSelectQuestSettings(SMCParser hParser, const char[] sKey, const char[] sValue, bool bKeyQuotes, bool bValueQuotes)
{
	if(!strcmp(sKey, "event"))
	{
		int iIndex = g_hEventsList.FindString(sValue);

		if(iIndex == -1)
		{
			iIndex = g_hEventsList.PushString(sValue);
			HookEventEx(sValue, OnEventHandler);
		}

		g_QuestAwardedData.iEventIndex = iIndex;
	}
	else if(!strcmp(sKey, "belong"))
	{
		int iIndex = g_hEventsBelongs.FindString(sValue);

		if(iIndex == -1)
		{
			iIndex = g_hEventsBelongs.PushString(sValue);
		}

		g_QuestAwardedData.iEventBelongIndex = iIndex;
	}
	else if(!strcmp(sKey, "amount"))
	{
		g_QuestAwardedData.iGiveExp = StringToInt(sValue);
	}
	else if(!strcmp(sKey, "count"))
	{
		g_QuestAwardedData.iMaxProgress = StringToInt(sValue);
	}
}

SMCResult OnSelectConditionSettings(SMCParser hParser, const char[] sKey, const char[] sValue, bool bKeyQuotes, bool bValueQuotes)
{
	int iIndexValue = g_hConditionParams.FindString(sKey);

	if(iIndexValue == -1)
	{
		iIndexValue = g_hConditionParams.PushString(sKey);
	}

	int iIndex = g_QuestAwardedData.hCondition.Push(iIndexValue);

	if((iIndexValue = g_hConditionValues.FindString(sValue)) == -1)
	{
		iIndexValue = g_hConditionValues.PushString(sValue);
	}

	g_QuestAwardedData.hCondition.Set(iIndex, iIndexValue, 1);
}

SMCResult OnNewSectionSettings(SMCParser hParser, const char[] sName, bool bOptQuotes)
{
	switch(++g_iSection)
	{
		case 1:
		{
			hParser.OnKeyValue = OnSelectSettings;
		}
		case 2:
		{
			g_QuestAwardedData.hCondition = new ArrayList(2);
			g_QuestAwardedData.iNameIndex = g_hQuestsName.PushString(sName);

			hParser.OnKeyValue = OnSelectQuestSettings;
		}
		case 3:
		{
			hParser.OnKeyValue = OnSelectConditionSettings;
		}
	}
}

SMCResult OnEndSectionSettings(SMCParser hParser)
{
	if(--g_iSection == 1)
	{
		g_hQuests.PushArray(g_QuestAwardedData, sizeof(g_QuestAwardedData));
		hParser.OnKeyValue = INVALID_FUNCTION;
	}
	else if(g_iSection == 2)
	{
		hParser.OnKeyValue = OnSelectQuestSettings;
	}
}

void OnEventHandler(Event hEvent, const char[] sName, bool bDontBroadcast)
{
	if(LR_CheckCountPlayers())
	{
		int iEventIndex = g_hEventsList.FindString(sName);

		if(iEventIndex != -1)
		{
			for(int iQuestIndex = 0, iLength = g_hQuests.Length; iQuestIndex != iLength; iQuestIndex++)
			{
				if(g_hQuests.Get(iQuestIndex, QuestAwardedData::iEventIndex) == iEventIndex)
				{
					decl char sBuffer[128];

					g_hEventsBelongs.GetString(g_hQuests.Get(iQuestIndex, QuestAwardedData::iEventBelongIndex), sBuffer, 32);

					int iClient = GetClientOfUserId(hEvent.GetInt(sBuffer));

					if(iClient && LR_GetClientStatus(iClient) && g_hPlayerQuests[iClient])
					{
						int iPlayerIndex = g_hPlayerQuests[iClient].FindValue(iQuestIndex, PlayerData::iQuestIndex);

						if(iPlayerIndex != -1)
						{
							int iCondition = 0;

							{
								decl char sParam[32], sExpectedValue[32], sRealValue[32];

								ArrayList hCondition = g_hQuests.Get(iQuestIndex, QuestAwardedData::hCondition);

								int iLen = hCondition.Length;

								if(iLen)
								{
									int i = 0;

									while(i != iLen)
									{
										g_hConditionParams.GetString(hCondition.Get(i, 0), sParam, sizeof(sParam));
										g_hConditionValues.GetString(hCondition.Get(i++, 1), sExpectedValue, sizeof(sExpectedValue));

										hEvent.GetString(sParam, sRealValue, sizeof(sRealValue));

										// LogMessage("%s: %s ?= %s", sParam, sExpectedValue, sRealValue);

										if(!strcmp(sExpectedValue, sRealValue))
										{
											iCondition++;
										}
									}
								}
								else
								{
									iCondition = 1;
								}

								if(iCondition < iLen)
								{
									iCondition = 0;
								}
							}

							// LogMessage("iCondition - %i", iCondition);

							if(iCondition)
							{
								int iProgress = g_hPlayerQuests[iClient].Get(iPlayerIndex, PlayerData::iProgress);

								if(iProgress != -1)
								{
									if(iProgress + 1 >= g_hQuests.Get(iQuestIndex, QuestAwardedData::iMaxProgress))
									{
										int iGiveExp = g_hQuests.Get(iQuestIndex, QuestAwardedData::iGiveExp);

										if(LR_ChangeClientValue(iClient, iGiveExp))
										{
											g_hQuestsName.GetString(g_hQuests.Get(iQuestIndex, QuestAwardedData::iNameIndex), sBuffer, sizeof(sBuffer));

											if(TranslationPhraseExists(sBuffer))
											{
												Format(sBuffer, sizeof(sBuffer), "%T", sBuffer, iClient);
											}

											LR_PrintToChat(iClient, true, "%T", "QuestComplite", iClient, LR_GetClientInfo(iClient, ST_EXP), GetSignValue(iGiveExp), sBuffer);
											g_hPlayerQuests[iClient].Set(iPlayerIndex, -1, PlayerData::iProgress);
										}
									}
									else
									{
										g_hPlayerQuests[iClient].Set(iPlayerIndex, iProgress + 1, PlayerData::iProgress);
									}
								}
							}
						}
					}
				}
			}
		}
	}
}

char[] GetSignValue(int iValue)
{
	bool bPlus = iValue > 0;

	decl char sValue[16];

	if(bPlus)
	{
		sValue[0] = '+';
	}

	IntToString(iValue, sValue[view_as<int>(bPlus)], sizeof(sValue) - view_as<int>(bPlus));

	return sValue;
}

void LoadDataPlayer(int iClient, int iAccountID)
{
	decl char sBuffer[128];

	FormatEx(sBuffer, sizeof(sBuffer), SQL_LOAD_DATA, g_sTableName, g_iAccountID[iClient] = iAccountID);
	g_hDatabase.Query(SQL_Callback, sBuffer, GetClientUserId(iClient) << 4);
}

void SQL_TransactionLoadPlayers(Database hDatabase, int iData, int iNumQueries, const DBResultSet[] hResults, const int[] iUserIDs)
{
	decl int iClient;

	for(int i = 0; i != iNumQueries; i++)
	{
		if((iClient = GetClientOfUserId(iUserIDs[i])))
		{
			SQL_LoadPlayer(iClient, hResults[i]);
		}
	}
}

void SQL_TransactionFailure(Database hDatabase, int iData, int iNumQueries, const char[] sError, int iFailIndex, const any[] iQueryData)
{
	if(sError[0])
	{
		LogError("SQL_TransactionFailure (%i): %s", iData, sError);
	}
}

void SQL_Callback(Database hDatabase, DBResultSet hResult, const char[] sError, int iData)
{
	if(sError[0])
	{
		LogError("SQL_Callback Error (%i) - %s", iData, sError);

		return;
	}

	switch(iData)
	{
		case 0, 2:
		{
			decl char sQuery[256];

			Transaction hTransaction = new Transaction();

			for(int i = MaxClients + 1; --i;)
			{
				if(LR_GetClientStatus(i))
				{
					FormatEx(sQuery, sizeof(sQuery), SQL_LOAD_DATA, g_sTableName, g_iAccountID[i] = GetSteamAccountID(i));
					hTransaction.AddQuery(sQuery, GetClientUserId(i));
				}
			}

			g_hDatabase.Execute(hTransaction, SQL_TransactionLoadPlayers, SQL_TransactionFailure, 1);
		}

		default:
		{
			if(iData >> 4)
			{
				iData = GetClientOfUserId(iData >> 4);		// iClient

				if(iData)
				{
					SQL_LoadPlayer(iData, hResult);
				}
			}
		}
	}
}

void SQL_LoadPlayer(const int &iClient, const DBResultSet &hResult)
{
	decl int iIndex;

	decl PlayerData Data;

	decl char sQuestName[64];

	if(hResult.HasResults && hResult.FetchRow())
	{
		g_hPlayerQuests[iClient] = new ArrayList(sizeof(PlayerData));

		do
		{
			hResult.FetchString(0, sQuestName, sizeof(sQuestName));

			// LogMessage("SQL_LoadPlayer: %s - %i", sQuestName, hResult.FetchInt(1));

			if((iIndex = g_hQuestsName.FindString(sQuestName)) != -1 && (iIndex = g_hQuests.FindValue(iIndex, QuestAwardedData::iNameIndex)) != -1)
			{
				Data.iQuestIndex = iIndex;
				Data.iProgress = hResult.FetchInt(1);

				// LogMessage("SQL_LoadPlayer2: iIndex == %i (%i)", iIndex, g_hQuests.Length);

				g_hPlayerQuests[iClient].PushArray(Data, sizeof(Data));
			}
		}
		while(hResult.FetchRow());
	}
	else
	{
		static int iStaticRandom = 0;

		decl int iLen, iQuestsLength;

		int iQuestsLength2 = g_hQuests.Length;

		iQuestsLength = iQuestsLength2 > g_iQuestsCount ? g_iQuestsCount : iQuestsLength;

		decl char sBuffer[1024];

		g_hPlayerQuests[iClient] = new ArrayList(sizeof(PlayerData), iQuestsLength);

		FormatEx(sBuffer, sizeof(sBuffer), SQL_INSERT_DATA, g_sTableName);

		for(int i = 0, iTime = GetTime(); i != iQuestsLength; i++)
		{
			Data.iQuestIndex = (iTime + ++iStaticRandom) % iQuestsLength2;
			Data.iProgress = 0;

			g_hPlayerQuests[iClient].SetArray(i, Data, sizeof(Data));

			g_hQuestsName.GetString(g_hQuests.Get(Data.iQuestIndex, QuestAwardedData::iNameIndex), sQuestName, sizeof(sQuestName));

			Format(sBuffer[iLen = strlen(sBuffer)], sizeof(sBuffer) - iLen, "(%u, '%s'), ", g_iAccountID[iClient], sQuestName);
		}

		if(iQuestsLength)
		{
			sBuffer[strlen(sBuffer) - 2] = ';';
			// LogMessage("%s", sBuffer);
			g_hDatabase.Query(SQL_Callback, sBuffer, 1);
		}
	}
}

static const char g_sMenuItem[] = "quests";

void OnMenuCreated(LR_MenuType MenuType, int iClient, Menu hMenu)
{
	int iFlags = GetUserFlagBits(iClient);

	if(!g_iAdminFlags || (g_iAdminFlags & iFlags == g_iAdminFlags || iFlags & ADMFLAG_ROOT))
	{
		decl char sBuffer[128];

		FormatEx(sBuffer, sizeof(sBuffer), "%T", "MenuTitle", iClient);
		hMenu.AddItem(g_sMenuItem, sBuffer);
	}
}

void OnMenuItemSelected(LR_MenuType MenuType, int iClient, const char[] sItem)
{
	if(!strcmp(sItem, g_sMenuItem))
	{
		QuestsMenu(iClient);
	}
}

Action OnEnterCommand(int iClient, int iArgs)
{
	if(iClient && LR_GetClientStatus(iClient))
	{
		QuestsMenu(iClient);
	}

	return Plugin_Handled;
}

void QuestsMenu(int iClient)
{
	int iFlags = GetUserFlagBits(iClient);

	if(!g_iAdminFlags || (g_iAdminFlags & iFlags == g_iAdminFlags || iFlags & ADMFLAG_ROOT))
	{
		decl int iQuestIndex;

		decl char sItem[256];

		ArrayList hPlayerQuests = g_hPlayerQuests[iClient];

		if(hPlayerQuests)
		{
			Menu hMenu = new Menu(QuestsMenu_Callback);

			SetGlobalTransTarget(iClient);

			hMenu.SetTitle("%s | %t\n ", g_sTitleMenu, "MenuTitle");

			for(int i = 0, iLen = hPlayerQuests.Length; i != iLen; i++)
			{
				g_hQuestsName.GetString(g_hQuests.Get(iQuestIndex = hPlayerQuests.Get(i, PlayerData::iQuestIndex), QuestAwardedData::iNameIndex), sItem, sizeof(sItem));

				if(g_hPlayerQuests[iClient].Get(i, PlayerData::iProgress) != -1)
				{
					Format(sItem, sizeof(sItem), TranslationPhraseExists(sItem) ? "%t [%s]" : "%s [%i / %i]", sItem, hPlayerQuests.Get(i, PlayerData::iProgress), g_hQuests.Get(iQuestIndex, QuestAwardedData::iMaxProgress));
				}
				else
				{
					Format(sItem, sizeof(sItem), TranslationPhraseExists(sItem) ? "%t [%t]" : "%s [%t]", sItem, "Complete");
				}

				hMenu.AddItem(NULL_STRING, sItem);
			}

			hMenu.ExitBackButton = true;
			hMenu.Display(iClient, MENU_TIME_FOREVER);
		}
	}
}

int QuestsMenu_Callback(Menu hMenu, MenuAction iAction, int iClient, int iSlot)
{
	switch(iAction)
	{
		case MenuAction_Select:
		{
			decl int iQuestIndex;

			decl char sItem[256];

			hMenu.RemoveAllItems();

			ArrayList hPlayerQuests = g_hPlayerQuests[iClient];

			for(int i = 0, iLen = hPlayerQuests.Length; i != iLen; i++)
			{
				g_hQuestsName.GetString(g_hQuests.Get(iQuestIndex = hPlayerQuests.Get(i, PlayerData::iQuestIndex), QuestAwardedData::iNameIndex), sItem, sizeof(sItem));

				if(g_hPlayerQuests[iClient].Get(i, PlayerData::iProgress) != -1)
				{
					Format(sItem, sizeof(sItem), TranslationPhraseExists(sItem) ? "%t [%s]" : "%s [%i / %i]", sItem, hPlayerQuests.Get(i, PlayerData::iProgress), g_hQuests.Get(iQuestIndex, QuestAwardedData::iMaxProgress));
				}
				else
				{
					Format(sItem, sizeof(sItem), TranslationPhraseExists(sItem) ? "%t [%t]" : "%s [%t]", sItem, "Complete");
				}

				hMenu.AddItem(NULL_STRING, sItem);
			}

			hMenu.Display(iClient, MENU_TIME_FOREVER);
		}

		case MenuAction_Cancel:
		{
			if(iSlot == MenuCancel_ExitBack)
			{
				LR_ShowMenu(iClient, LR_SettingMenu);
			}
		}

		case MenuAction_End:
		{
			if(iSlot == MENUFLAG_BUTTON_EXIT)
			{
				hMenu.Close();
			}
		}
	}
}

public void OnClientDisconnect(int iClient)
{
	if(g_hPlayerQuests[iClient])
	{
		decl char sBuffer[256];

		ArrayList hPlayerQuests = g_hPlayerQuests[iClient];

		Transaction hTransaction = new Transaction();

		for(int i = 0, iLen = hPlayerQuests.Length; i != iLen; i++)
		{
			g_hQuestsName.GetString(g_hQuests.Get(hPlayerQuests.Get(i, PlayerData::iQuestIndex), QuestAwardedData::iNameIndex), sBuffer, sizeof(sBuffer));
			Format(sBuffer, sizeof(sBuffer), SQL_UPDATE_DATA, g_sTableName, hPlayerQuests.Get(i, PlayerData::iProgress), g_iAccountID[iClient], sBuffer);
			hTransaction.AddQuery(sBuffer, i);
		}

		g_hDatabase.Execute(hTransaction, _, SQL_TransactionFailure, 2);

		delete g_hPlayerQuests[iClient];
	}
}

/*
public void OnPluginEnd()
{
	for(int i = MaxClients + 1; --i;)
	{
		OnClientDisconnect(i);
	}
}
*/